{-# LANGUAGE LambdaCase, TupleSections, DataKinds, RecursiveDo, RecordWildCards, OverloadedStrings, TemplateHaskell #-}

module Reducer.LLVM.Base where

import Text.Printf
import Control.Monad as M
import Control.Monad.State
import Data.Functor.Foldable as Foldable
import Lens.Micro.Platform

import Data.Word
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector (Vector)

import Grin
import qualified TypeEnv

import LLVM.AST as LLVM hiding (callingConvention)
import LLVM.AST.Type as LLVM
import LLVM.AST.AddrSpace
import LLVM.AST.Constant hiding (Add, ICmp)
import LLVM.AST.IntegerPredicate
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Linkage as L
import qualified LLVM.AST as AST
import LLVM.AST.Global
import LLVM.Context
import LLVM.Module

import Control.Monad.Except
import qualified Data.ByteString.Char8 as BS
data Env
  = Env
  { _envDefinitions       :: [Definition]
  , _envBasicBlocks       :: [BasicBlock]
  , _envInstructions      :: [Named Instruction]
  , _constantMap          :: Map Grin.Name Operand
  , _currentBlockName     :: AST.Name
  , _envBlockInstructions :: Map AST.Name [Named Instruction]
  , _envTempCounter       :: Int
  , _envTypeEnv           :: TypeEnv.TypeEnv
  , _envTagMap            :: Map Tag Constant
  }

emptyEnv = Env
  { _envDefinitions       = mempty
  , _envBasicBlocks       = mempty
  , _envInstructions      = mempty
  , _constantMap          = mempty
  , _currentBlockName     = mkName ""
  , _envBlockInstructions = mempty
  , _envTempCounter       = 0
  , _envTypeEnv           = TypeEnv.TypeEnv mempty mempty mempty
  , _envTagMap            = mempty
  }

concat <$> mapM makeLenses [''Env]

-- Tagged union
{-
  HINT: tagged union LLVM representation

    struct {
      Int64[N1];
      Word64[N2];
      ...
    }
-}
data TUIndex
  = TUIndex
  { tuStructIndex   :: Word32
  , tuArrayIndex    :: Word32
  , tuItemLLVMType  :: LLVM.Type
  }
  deriving (Eq, Ord, Show)

data TaggedUnion
  = TaggedUnion
  { tuLLVMType  :: LLVM.Type -- struct of arrays of SimpleType with size
  , tuMapping   :: Map Tag (Vector TUIndex)
  }
  deriving (Eq, Ord, Show)

data CGType
  = CG_SimpleType
    { cgLLVMType    :: LLVM.Type
    , cgType        :: TypeEnv.Type
    }
  | CG_NodeSet
    { cgLLVMType    :: LLVM.Type
    , cgType        :: TypeEnv.Type
    , cgTaggedUnion :: TaggedUnion
    }
  deriving (Eq, Ord, Show)

type CG = State Env

emit :: [Named Instruction] -> CG ()
emit instructions = modify' (\env@Env{..} -> env {_envInstructions = _envInstructions ++ instructions})

addConstant :: Grin.Name -> Operand -> CG ()
addConstant name operand = modify' (\env@Env{..} -> env {_constantMap = Map.insert name operand _constantMap})

unit :: Operand
unit = ConstantOperand $ Undef VoidType

undef :: Type -> Operand
undef = ConstantOperand . Undef

data Result
  = I CGType Instruction
  | O CGType Operand

-- utils
closeBlock :: Terminator -> CG ()
closeBlock tr = modify' $ \env@Env{..} -> env
  { _envInstructions      = mempty
  , _envBasicBlocks       = _envBasicBlocks ++ [BasicBlock _currentBlockName _envInstructions (Do tr)]
  , _envBlockInstructions = Map.delete _currentBlockName _envBlockInstructions
  }

activeBlock :: AST.Name -> CG ()
activeBlock name =  modify' $ \env@Env{..} -> env
  { _envInstructions      = Map.findWithDefault mempty name _envBlockInstructions
  , _currentBlockName     = name
  , _envBlockInstructions = Map.insert _currentBlockName _envInstructions _envBlockInstructions
  }

addBlock :: AST.Name -> CG a -> CG a
addBlock name block = do
  curBlockName <- gets _currentBlockName
  activeBlock name
  result <- block
  activeBlock curBlockName
  pure result

uniqueName :: String -> CG AST.Name
uniqueName name = state (\env@Env{..} -> (mkName $ printf "%s.%d" name _envTempCounter, env {_envTempCounter = succ _envTempCounter}))

getOperand :: String -> Result -> CG (CGType, Operand)
getOperand name = \case
  O cgTy a -> pure (cgTy, a)
  I cgTy i -> case cgLLVMType cgTy of
    VoidType  -> emit [Do i] >> pure (cgTy, unit)
    t         -> (cgTy,) <$> codeGenLocalVar name t i

codeGenLocalVar :: String -> LLVM.Type -> AST.Instruction -> CG LLVM.Operand
codeGenLocalVar name ty instruction = do
  varName <- uniqueName name
  emit [varName := instruction]
  pure $ LocalReference ty varName

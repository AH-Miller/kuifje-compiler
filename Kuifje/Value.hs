module Kuifje.Value where

import qualified Kuifje.Env as E
import qualified Data.Set as DSET

data Value = R Rational 
           | B Bool 
           | S (DSET.Set Value) 
           deriving (Show, Eq, Ord)
type Gamma = E.Env Value 

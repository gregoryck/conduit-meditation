{-# LANGUAGE OverloadedStrings #-}
import Data.Conduit -- the core library
import qualified Data.Conduit.List as CL -- some list-like functions
import qualified Data.Conduit.Binary as CB -- bytes
import qualified Data.Conduit.Text as CT

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Control.Monad.ST (runST)

-- Let's start with the basics: connecting a source to a sink. We'll use the
-- built in file functions to implementing efficient, constant-memory,
-- resource-friendly file copying.
--
-- Two things to note: we use $$ to connect our source to our sink, and then
-- use runResourceT.
copyFile :: FilePath -> FilePath -> IO ()
copyFile src dest = runResourceT $ CB.sourceFile src $$ CB.sinkFile dest


-- The Data.Conduit.List module provides a number of helper functions for
-- creating sources, sinks, and conduits. Let's look at a typical fold: summing
-- numbers.
sumSink :: Resource m => Sink Int m Int
sumSink = CL.fold (+) 0

-- If we want to go a little more low-level, we can code our sink with the
-- sinkState function. This function takes three parameters: an initial state,
-- a push function (receive some more data), and a close function.
sumSink2 :: Resource m => Sink Int m Int
sumSink2 = sinkState
    0 -- initial value

    -- update the state with the new input and
    -- indicate that we want more input
    (\accum i -> return $ StateProcessing (accum + i))
    (\accum -> return accum) -- return the current accum value on close

-- Another common helper function is sourceList. Let's see how we can combine
-- that function with our sumSink to reimplement the built-in sum function.
sum' :: [Int] -> Int
sum' input = runST $ runResourceT $ CL.sourceList input $$ sumSink

-- Since this is Haskell, let's write a source to generate all of the
-- Fibonacci numbers. We'll use sourceState. The state will contain the next
-- two numbers in the sequence. We also need to provide a pull function, which
-- will return the next number and update the state.
fibs :: Resource m => Source m Int
fibs = sourceState
    (0, 1) -- initial state
    (\(x, y) -> return $ StateOpen (y, x + y) x)

-- Suppose we want to get the sum of the first 10 Fibonacci numbers. We can use
-- the isolate conduit to make sure the sum sink only consumes 10 values.
sumTenFibs :: Int
sumTenFibs =
       runST -- runs fine in pure code
     $ runResourceT
     $ fibs
    $= CL.isolate 10 -- fuse the source and conduit into a source
    $$ sumSink

-- We can also fuse the conduit into the sink instead, we just swap a few
-- operators.
sumTenFibs2 :: Int
sumTenFibs2 =
       runST
     $ runResourceT
     $ fibs
    $$ CL.isolate 10
    =$ sumSink

-- Alright, let's make some conduits. Let's turn our numbers into text. Sounds
-- like a job for a map...

intToText :: Int -> Text -- just a helper function
intToText = T.pack . show

textify :: Resource m => Conduit Int m Text
textify = CL.map intToText

-- Like previously, we can use a conduitState helper function. But here, we
-- don't even need state, so we provide a dummy state value.
textify2 :: Resource m => Conduit Int m Text
textify2 = conduitState
    ()
    (\() input -> return $ StateProducing () [intToText input])
    (\() -> return [])

-- Let's make the unlines conduit, that puts a newline on the end of each piece
-- of input. We'll just use CL.map; feel free to write it with conduitState as
-- well for practice.
unlines' :: Resource m => Conduit Text m Text
unlines' = CL.map $ \t -> t `T.append` "\n"

-- And let's write a function that prints the first N fibs to a file. We'll
-- use UTF8 encoding.
writeFibs :: Int -> FilePath -> IO ()
writeFibs count dest =
      runResourceT
    $ fibs
   $= CL.isolate count
   $= textify
   $= unlines'
   $= CT.encode CT.utf8
   $$ CB.sinkFile dest

-- We used the $= operator to fuse the conduits into the sources, producing a
-- single source. We can also do the opposite: fuse the conduits into the sink. We can even combine the two.
writeFibs2 :: Int -> FilePath -> IO ()
writeFibs2 count dest =
      runResourceT
    $ fibs
   $= CL.isolate count
   $= textify
   $$ unlines'
   =$ CT.encode CT.utf8
   =$ CB.sinkFile dest

-- Or we could fuse all those inner conduits into a single conduit...
someIntLines :: ResourceThrow m -- encoding can throw an exception
             => Int
             -> Conduit Int m ByteString
someIntLines count =
      CL.isolate count
  =$= textify
  =$= unlines'
  =$= CT.encode CT.utf8

-- and then use that conduit
writeFibs3 :: Int -> FilePath -> IO ()
writeFibs3 count dest =
      runResourceT
    $ fibs
   $= someIntLines count
   $$ CB.sinkFile dest

main :: IO ()
main = do
    putStrLn $ "First ten fibs: " ++ show sumTenFibs
    writeFibs 20 "fibs.txt"
    copyFile "fibs.txt" "fibs2.txt"


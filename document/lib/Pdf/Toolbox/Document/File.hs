{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- |
-- PDF file as container for objects

module Pdf.Toolbox.Document.File
(
  File(..),
  NotFound(..),
  withBuffer
)
where

import Data.Typeable
import Data.IORef
import Data.ByteString (ByteString)
import qualified Data.HashMap.Strict as HashMap
import Control.Monad
import Control.Exception hiding (throw)
import System.IO.Streams (InputStream)

import Pdf.Toolbox.Core hiding (trailer)
import qualified Pdf.Toolbox.Core as Core
import Pdf.Toolbox.Core.Util
import Pdf.Toolbox.Core.IO.Buffer (Buffer)

import Pdf.Toolbox.Document.Encryption

-- | PDF file
--
-- It doesn't perform decryption or decoding
data File = File
  { object :: Ref -> IO (Object, Bool)
  , stream :: Stream -> IO (InputStream ByteString)
  , trailer :: IO Dict
  , setDecryptor :: Decryptor -> IO ()
  }

data File_ = File_
  { _lastXRef :: XRef
  , _buffer :: Buffer
  , _filters :: [StreamFilter]
  , _decrRef :: IORef (Maybe Decryptor)
  }

-- | PDF file from buffer
withBuffer :: [StreamFilter] -> Buffer -> IO File
withBuffer filters buf = do
  xref <- lastXRef buf
  decrRef <- newIORef Nothing
  let file = File_
        { _lastXRef = xref
        , _buffer = buf
        , _filters = filters
        , _decrRef = decrRef
        }
  return File
    { object = findObject file
    , stream = streamContent file
    , trailer = Core.trailer buf xref
    , setDecryptor = writeIORef decrRef . Just
    }

findObject :: File_ -> Ref -> IO (Object, Bool)
findObject file ref =
  (lookupEntryRec file ref
  >>= readObjectForEntry file)
    -- unknown type should be interpreted as reference to null object
    `catch` \(UnknownXRefStreamEntryType _) -> return (Null, False)

streamContent :: File_ -> Stream -> IO (InputStream ByteString)
streamContent file (S dict pos) = do
  len <- do
    obj <- sure $ HashMap.lookup "Length" dict `notice` "Length missing in stream"
    case obj of
      Number _ -> sure $ intValue obj `notice` "Length should be an integer"
      Ref ref -> do
        (o, _) <- findObject file ref
        sure $ intValue o `notice` "Length should be an integer"
      _ -> throwIO $ Corrupted "Length should be an integer" []
  rawStreamContent (_buffer file) len pos

readObjectForEntry :: File_-> XRefEntry -> IO (Object, Bool)
readObjectForEntry file (XRefTableEntry entry)
  | teIsFree entry = return (Null, False)
  | otherwise = do
    (R _ gen, obj) <- readObjectAtOffset (_buffer file) (teOffset entry)
    unless (gen == teGen entry) $
      throwIO (Corrupted "readObjectForEntry" ["object generation missmatch"])
    return (obj, False)
readObjectForEntry file (XRefStreamEntry entry) =
  case entry of
    StreamEntryFree{} -> return (Null, False)
    StreamEntryUsed off _ -> do
      obj <- readObjectAtOffset (_buffer file) off
      return (snd obj, False)
    StreamEntryCompressed index num -> do
      objStream@(S dict _) <- do
        (o, _) <- findObject file (R index 0)
        sure $ streamValue o `notice` "Compressed entry should be in stream"
      first <- sure $ (HashMap.lookup "First" dict >>= intValue)
          `notice` "First should be an integer"
      raw <- streamContent file objStream
      decrypted <-
        readIORef (_decrRef file)
        >>= maybe (return raw)
          (\decr -> decr (R index 0) DecryptStream raw)
      decoded <- decodeStream (_filters file) objStream decrypted
      obj <- readCompressedObject decoded (fromIntegral first) num
      return (obj, True)

lookupEntryRec :: File_ -> Ref -> IO XRefEntry
lookupEntryRec file ref = loop (_lastXRef file)
  where
  loop xref = do
    res <- lookupEntry file ref xref
    case res of
      Just e -> return e
      Nothing -> do
        prev <- prevXRef (_buffer file) xref
        case prev of
          Just p -> loop p
          Nothing -> throwIO (NotFound $ "The Ref not found: " ++ show ref)

lookupEntry :: File_ -> Ref -> XRef -> IO (Maybe XRefEntry)
lookupEntry file ref xref@(XRefTable _) =
  fmap XRefTableEntry <$> lookupTableEntry (_buffer file) xref ref
lookupEntry file ref (XRefStream _ s@(S dict _)) = do
  raw <- streamContent file s
  decoded <- decodeStream (_filters file) s raw
  fmap XRefStreamEntry <$> lookupStreamEntry dict decoded ref

data NotFound = NotFound String
  deriving (Show, Typeable)

instance Exception NotFound
module Main where

import Prelude
import Data.Foreign.Generic as DFG
import Control.IxMonad (ibind, (:*>), (:>>=))
import Control.Monad.Aff (Aff, Canceler, launchAff)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Console (error)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Except (runExcept)
import Data.Either (Either(..))
import Data.Foreign.Class (class IsForeign, readJSON, write)
import Data.Generic.Rep (class Generic)
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Data.Tuple (Tuple(Tuple))
import Global.Unsafe (unsafeStringify)
import Hyper.Middleware (Middleware, lift')
import Hyper.Middleware.Class (getConn)
import Hyper.Node.FileServer (fileServer)
import Hyper.Node.Server (defaultOptions, runServer)
import Hyper.Request (readBody)
import Hyper.Response (headers, respond, writeStatus)
import Hyper.Status (statusBadRequest, statusNotFound, statusOK)
import Node.Buffer (BUFFER)
import Node.Encoding (Encoding(UTF8))
import Node.FS (FS)
import Node.FS.Aff (readdir)
import Node.HTTP (HTTP)
import Node.Path (concat)
import Node.Process (PROCESS, lookupEnv)
import SQLite3 (DBEffects, newDB, queryDB)

newtype UpdateRequest = UpdateRequest
  { path :: String
  , watched :: Boolean
  }
derive instance grUR :: Generic UpdateRequest _
instance ifUR :: IsForeign UpdateRequest where
  read = DFG.readGeneric $ DFG.defaultOptions {unwrapSingleConstructors = true}

lift'' :: forall t5 t6 t7 t8.
  ( Monad t7
  , MonadAff t8 t7
  ) => Aff t8 t5 -> Middleware t7 t6 t6 t5
lift'' = lift' <<< liftAff

type AppEffects eff =
  ( avar :: AVAR
  , console :: CONSOLE
  , db :: DBEffects
  , process :: PROCESS
  , http :: HTTP
  , fs :: FS
  , buffer :: BUFFER
  | eff )

main :: forall eff.
  Eff (AppEffects (err :: EXCEPTION | eff))
    (Canceler (AppEffects eff))
main = launchAff do
  dir <- liftEff $ lookupEnv "FILETRACKER_DIR"
  case dir of
    Nothing -> error "we done broke now!!!!"
    Just path -> do
      db <- newDB $ concat [path, "filetracker"]
      liftEff $ runServer options {} (router path db)
  where
    router dir db = getConn :>>= handleConn dir db
    options = defaultOptions { onListening = onListening, onRequestError = onRequestError}
    onListening port = log $ "listening on " <> (show $ unwrap port)
    onRequestError error = log $ "error: " <> show error
    notFound =
      writeStatus statusNotFound
      :*> headers []
      :*> respond (Tuple "<h1>Not Found</h1>" UTF8)
    respondJSON json =
      writeStatus statusOK
      :*> headers [Tuple "Content-Type" "application/json"]
      :*> respond json
    readFiles path = lift'' $ unsafeStringify <<< write <$> readdir path
    handleConn dir db conn =
      case Tuple conn.request.method conn.request.url of
        Tuple (Left GET) "/api/files" -> do
          files <- readFiles dir
          respondJSON files
        Tuple (Left GET) "/api/watched" -> do
          watched
        Tuple (Left POST) "/api/update" -> do
          update
        _ -> fileServer "dist" notFound
        where
          bind = ibind
          queryDB' q p = lift'' $ queryDB db q p
          update = do
            body <- readBody
            case runExcept $ readJSON body of
              Right (UpdateRequest ur) -> do
                _ <- if ur.watched
                  then queryDB' "INSERT OR REPLACE INTO watched (path, created) VALUES ($1, datetime());" [ur.path]
                  else queryDB' "DELETE FROM watched WHERE path = $1" [ur.path]
                watched
              Left e -> do
                writeStatus statusBadRequest
                headers []
                respond $ "you gave me bad JSON!!!\n" <> show e <> "\nin\n" <> body
          watched = do
            -- should come back as [{path :: String, created :: String}]
            -- demand refund if not
            a <- queryDB' "SELECT path, created FROM watched;" []
            respondJSON $ unsafeStringify a

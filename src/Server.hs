module Server
( runServer
) where

import Control.Concurrent
import Control.Concurrent.Chan

import Control.Exception
import Control.Monad

import GHC.IO.Handle
import System.IO
import Network.Socket

data Message = Message 
    { content :: String
    , author :: String
    } deriving (Show)

type Channel = Chan Message

addrInfo :: IO AddrInfo
addrInfo = fmap head $ getAddrInfo (Just hints) Nothing (Just "3000")
    where
        hints = defaultHints 
            { addrFlags = [AI_PASSIVE]
            , addrSocketType = Stream
            }

createSocket :: AddrInfo -> IO Socket
createSocket addr = do 
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)

    -- in case something goes wrong
    setCloseOnExecIfNeeded $ fdSocket sock

    listen sock 10 -- 10 users
    pure sock

runLoop :: Channel -> Socket -> IO ()
runLoop chan sock = forever $ do
    (conn, addr) <- accept sock -- accept the next connection
    putStrLn $ "Connection from " ++ (show addr)
    copiedChan <- dupChan chan
    forkFinally (runClient copiedChan conn) (\_ -> close conn)

runClient :: Channel -> Socket -> IO ()
runClient chan sock = do
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl NoBuffering

    hPutStrLn hdl "What's your name ?"
    author <- fmap init $ hGetLine hdl

    let authorOnlineMsg = author ++ " is online"
    putStrLn authorOnlineMsg
    writeChan chan $ Message authorOnlineMsg "Server"

    copiedChan <- dupChan chan
    th <- forkIO $ receiver author copiedChan hdl
    try $ sender author chan hdl :: IO (Either SomeException ())

    let authorOfflineMsg = author ++ " is offline"
    putStrLn authorOnlineMsg
    writeChan chan $ Message authorOfflineMsg "Server"
    end hdl th

    where
        -- Will transmit any message in the chan to the user
        receiver :: String -> Channel -> Handle -> IO ()
        receiver author chan hdl = forever $ do
            (Message msg msgAuthor) <- readChan chan
            when (msgAuthor /= author) $ hPutStrLn hdl $ "[" ++ msgAuthor ++ "] " ++  msg

        -- Will transmit any message from the user to the chan
        sender :: String -> Channel -> Handle -> IO ()
        sender author chan hdl = forever $ do
            msg <- hGetLine hdl
            writeChan chan $ Message msg author

        -- Close eveything
        end :: Handle -> ThreadId -> IO ()
        end hdl th = do
            killThread th
            hClose hdl

runServer :: IO ()
runServer = withSocketsDo $ do
    addr <- addrInfo
    putStrLn $ "Connecting to " ++ (show addr)

    let sock = createSocket addr

    -- create the common Chan
    chan <- newChan

    -- Empty the chan, because every socket will duplicate it and nobody will read from it
    forkIO . forever . void $ readChan chan

    -- create the socket, loop, then close it
    bracket sock close $ runLoop chan

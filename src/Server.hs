module Server
( runServer
) where

import Control.Concurrent
import Control.Concurrent.Chan

import Control.Exception
import Control.Monad

import Control.Concurrent.STM
import GHC.IO.Handle
import Network.Socket
import System.IO

import qualified Data.Map as M
import qualified Control.Monad.HT as HT
import Data.List

data Message = Message 
    { content :: String
    , author :: String
    } deriving (Show)

type Channel = Chan Message

data Room = Room
    { roomUsers :: [String]
    , roomName :: String 
    , channel :: Channel
    }
type Rooms = M.Map String Room

data Command = 
    SwitchRoom String |
    Quit |
    ChangeUserName String |
    UserList

data User = User
    { userName :: String
    , userHandle :: Handle
    }

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

enterRoom :: TVar Rooms -> String -> String -> IO Room
enterRoom rooms room user = do
    chan <- newChan
    (r@(Room _ name c), new) <- atomically (getRoom chan)

    -- Empty the chan, because every socket will duplicate it and nobody will read from it
    when new $ void . forkIO . forever $ do
        (Message msg msgAuthor) <- readChan c
        putStrLn $ "from '" ++ msgAuthor ++ "' in '" ++ name ++ "': " ++ msg 

    pure r

    where
        getRoom :: Channel -> STM (Room, Bool)
        getRoom chan = do
            rms <- readTVar rooms :: STM Rooms
            let r@((Room us name c), _) = getLastRoom rms room chan
    
            let newRoom = Room (user : us) name c
            let newRooms = M.insert room newRoom rms
    
            writeTVar rooms newRooms
            pure r
    
            where 
                getLastRoom :: Rooms -> String -> Channel -> (Room, Bool)
                getLastRoom rooms room chan = case M.lookup room rooms of
                    Nothing -> (Room [] room chan, True)
                    (Just r) -> (r, False) 

leaveRoom :: TVar Rooms -> String -> String -> IO ()
leaveRoom rooms room user = atomically $ do
    rms <- readTVar rooms :: STM Rooms
    let newRooms = M.update (removeUser user) room rms
    writeTVar rooms newRooms
    pure ()

    where
        removeUser :: String -> Room -> Maybe Room
        removeUser user (Room users name chan) = let nextUserList = filter (/= user) users in if null nextUserList then Nothing else Just $ Room nextUserList name chan

runLoop :: TVar Rooms -> Socket -> IO ()
runLoop rooms sock = forever $ do
    (conn, addr) <- accept sock -- accept the next connection
    putStrLn $ "Connection from " ++ (show addr)
    forkFinally (runClient rooms conn) (\_ -> close conn)

isValidUserName :: String -> Bool
isValidUserName name = name /= "Server" 

parseCommand :: String -> Maybe Command
parseCommand str = parse $ words str
    where
        parse :: [String] -> Maybe Command
        parse ["quit"] = Just Quit
        parse ["users"] = Just UserList
        parse ["move", room] = Just $ SwitchRoom room
        parse ["name", name] | isValidUserName name = Just $ ChangeUserName name
        parse _ = Nothing

putClientInRoom :: TVar Rooms -> User -> String -> IO ()
putClientInRoom rooms (User user hdl) = changeRoom
        where 
            changeRoom :: String -> IO ()
            changeRoom room = do
                (Room users _ chan) <- enterRoom rooms room user
                hPutStrLn hdl $ "You entered room " ++ room
                let onlineMsg = user ++ " entered the room " ++ room
                putStrLn onlineMsg
                writeChan chan $ Message onlineMsg "Server"
            
                copiedChan <- dupChan chan
                th <- forkIO $ receiver user copiedChan hdl
                eitherAction <- try $ sender user room chan hdl :: IO (Either SomeException (IO ()))
            
                leaveRoom rooms room user
                let offlineMsg = user ++ " exit the room " ++ room
                putStrLn offlineMsg
                writeChan chan $ Message offlineMsg "Server"
                killThread th
                case eitherAction of 
                    Left _ -> pure ()
                    Right a -> a
            
            -- Will transmit any message in the chan to the user
            receiver :: String -> Channel -> Handle -> IO ()
            receiver author chan hdl = forever $ do
                (Message msg msgAuthor) <- readChan chan
                when (msgAuthor /= author) $ hPutStrLn hdl $ "[" ++ msgAuthor ++ "] " ++  msg
    
            -- Will transmit any message from the user to the chan
            sender :: String -> String -> Channel -> Handle -> IO (IO ())
            sender author room chan hdl = loop 
                where 
                    loop = do
                        msg <- hGetLine hdl
                        if (not . null) msg && head msg == '/'
                            then do
                                let com = parseCommand $ tail msg
                                case com of
                                    Nothing -> do
                                        hPutStrLn hdl "[Server] Unknown command"
                                        putStrLn $ "[Server] " ++ author ++ " entered unknown command: " ++ (tail msg)
                                        loop

                                    Just Quit -> do
                                        putStrLn $ "[Server] " ++ author ++ " is leaving"
                                        pure $ pure ()

                                    Just (SwitchRoom nextRoom) -> do
                                        putStrLn $ "[Server] " ++ author ++ " switch room " ++ room ++ "=>" ++ nextRoom
                                        pure $ changeRoom nextRoom 

                                    Just (ChangeUserName newUser) -> do
                                        putStrLn $ "[Server] User change his name " ++ author ++ "=>" ++ newUser
                                        pure $ putClientInRoom rooms (User newUser hdl) room

                                    Just UserList -> do
                                        rs <- atomically $ readTVar rooms
                                        let users = roomUsers $ (M.!) rs room -- The room must exist as the user is in it
                                        hPutStrLn hdl $ "Users: " ++ (concat $ intersperse ", " users)
                                        putStrLn $ "[Server] " ++ author ++ " asks for the users in the room"
                                        loop
                            else do
                                writeChan chan $ Message msg author
                                loop
            
runClient :: TVar Rooms -> Socket -> IO ()
runClient rooms sock = do
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl NoBuffering

    name <- HT.until isValidUserName $ do
        hPutStrLn hdl "What's your name ?"
        fmap init $ hGetLine hdl

    putClientInRoom rooms (User name hdl) "waiting_room"
    hClose hdl

runServer :: IO ()
runServer = withSocketsDo $ do
    addr <- addrInfo
    putStrLn $ "Connecting to " ++ (show addr)

    let sock = createSocket addr

    -- Room List
    rooms <- atomically $ newTVar M.empty

    -- create the socket, loop, then close it
    bracket sock close $ runLoop rooms

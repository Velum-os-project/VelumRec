-- # ==============================================================================
-- # Velum OS - Core Enterprise Infrastructure
-- # Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
-- #
-- # This program is free software: you can redistribute it and/or modify
-- # it under the terms of the GNU Affero General Public License as published
-- # by the Free Software Foundation, either version 3 of the License, or
-- # (at your option) any later version.
-- #
-- # This program is distributed in the hope that it will be useful,
-- # but WITHOUT ANY WARRANTY; without even the implied warranty of
-- # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- # GNU Affero General Public License for more details.
-- #
-- # You should have received a copy of the GNU Affero General Public License
-- # along with this program. If not, see <https://gnu.org>.
-- # ==============================================================================
-- VelumRec - Integrity verification and error handler
-- CRITICAL MODULE — prevents catastrophic system states
-- Guards ALL operations in both standard and aggressive mode
-- A hung or partial kernel modification without this module
-- could leave the system permanently unrecoverable

module Integrity where

import Data.Digest.Pure.SHA
import qualified Data.ByteString.Lazy as BL
import System.Exit
import System.Directory
import System.IO
import Control.Exception
import Control.Concurrent (threadDelay, forkIO, killThread)
import Control.Concurrent.MVar
import Data.List (isPrefixOf)

-- Result type — exhaustive, no invalid states possible
data IntegrityResult
    = OK String
    | Failed String
    | Warning String
    | Timeout String     -- operation hung, must abort
    | Aborted String     -- operation was killed to prevent damage
    deriving (Show)

-- ================================================================
-- ERROR HANDLER
-- Catches any error thrown by C++ or HolyC operations
-- ================================================================

handleOperationError :: SomeException -> IO IntegrityResult
handleOperationError e =
    return $ Failed $ "Operation error: " ++ show e

-- Safe wrapper — catches any exception from C++ or HolyC
safeRun :: IO IntegrityResult -> IO IntegrityResult
safeRun action = catch action handleOperationError

-- ================================================================
-- WATCHDOG — detects hung operations (e.g. HolyC stuck in kernel)
-- If an operation exceeds the timeout, it's aborted and reported
-- ================================================================

withWatchdog :: Int -> String -> IO IntegrityResult -> IO IntegrityResult
withWatchdog seconds label action = do
    result <- newEmptyMVar
    tid <- forkIO $ do
        r <- safeRun action
        putMVar result r
    threadDelay (seconds * 1000000)
    empty <- isEmptyMVar result
    if empty
        then do
            killThread tid
            putStrLn $ "[integrity] WATCHDOG: " ++ label ++ " timed out after "
                     ++ show seconds ++ "s. Aborting to prevent kernel damage."
            return $ Timeout $ label ++ " exceeded time limit"
        else takeMVar result

-- ================================================================
-- SNAPSHOT — saves system state before an operation
-- Used to detect partial modifications if something goes wrong
-- ================================================================

data SystemSnapshot = SystemSnapshot
    { snapLSMLoaded  :: Bool
    , snapABACExists :: Bool
    , snapVTAExists  :: Bool
    } deriving (Show)

takeSnapshot :: IO SystemSnapshot
takeSnapshot = do
    lsm  <- doesFileExist "/proc/modules"
    abac <- doesDirectoryExist "/velum"
    vta  <- doesDirectoryExist "/velum/layer4/vta"
    return $ SystemSnapshot lsm abac vta

compareSnapshot :: SystemSnapshot -> SystemSnapshot -> [IntegrityResult]
compareSnapshot before after =
    [ check "LSM"  (snapLSMLoaded before)  (snapLSMLoaded after)
    , check "ABAC" (snapABACExists before) (snapABACExists after)
    , check "VTA"  (snapVTAExists before)  (snapVTAExists after)
    ]
  where
    check label True False = Failed $ label ++ " was present before but missing after operation"
    check label False True = Warning $ label ++ " appeared after operation — unexpected"
    check _ _ _            = OK "No change detected"

-- ================================================================
-- INTEGRITY CHECKS
-- ================================================================

verifyFile :: FilePath -> String -> IO IntegrityResult
verifyFile path expected = safeRun $ do
    exists <- doesFileExist path
    if not exists
        then return $ Failed $ "File not found: " ++ path
        else do
            contents <- BL.readFile path
            let actual = show (sha512 contents)
            if actual == expected
                then return $ OK $ "Verified: " ++ path
                else return $ Failed $ "Checksum mismatch: " ++ path

-- /proc/modules format: "module_name size refcount deps state address ..."
-- Match the first word of each line, not the whole line.
verifyLSM :: IO IntegrityResult
verifyLSM = safeRun $ do
    contents <- readFile "/proc/modules"
    let loaded = any (("velum_lsm" `isPrefixOf`) . takeWhile (/= ' ')) (lines contents)
    if loaded
        then return $ OK "LSM velum_lsm is loaded."
        else return $ Failed "velum_lsm is NOT loaded — system is unprotected."

verifyABAC :: IO IntegrityResult
verifyABAC = safeRun $ do
    exists <- doesDirectoryExist "/velum"
    if exists
        then return $ OK "ABAC directory matrix intact."
        else return $ Failed "/velum matrix missing or damaged."

verifyVTA :: IO IntegrityResult
verifyVTA = safeRun $ do
    exists <- doesDirectoryExist "/velum/layer4/vta"
    if exists
        then return $ OK "VTA configuration found."
        else return $ Failed "VTA configuration missing or corrupted."

verifyRecoveryBinaries :: [(FilePath, String)] -> IO [IntegrityResult]
verifyRecoveryBinaries = mapM (uncurry verifyFile)

-- ================================================================
-- EVALUATE AND PRINT
-- ================================================================

evalResult :: IntegrityResult -> IO Bool
evalResult (OK msg)      = putStrLn ("[integrity] OK: "      ++ msg) >> return True
evalResult (Failed msg)  = putStrLn ("[integrity] FAILED: "  ++ msg) >> return False
evalResult (Warning msg) = putStrLn ("[integrity] WARNING: " ++ msg) >> return True
evalResult (Timeout msg) = putStrLn ("[integrity] TIMEOUT: " ++ msg) >> return False
evalResult (Aborted msg) = putStrLn ("[integrity] ABORTED: " ++ msg) >> return False

-- ================================================================
-- PRE-OPERATION CHECK
-- Called by C++ UI before ANY operation
-- ================================================================

preCheck :: [(FilePath, String)] -> IO ()
preCheck files = do
    putStrLn "[integrity] Pre-operation integrity check..."
    results    <- sequence [verifyLSM, verifyABAC, verifyVTA]
    binResults <- verifyRecoveryBinaries files
    allOk      <- mapM evalResult (results ++ binResults)
    if and allOk
        then putStrLn "[integrity] Pre-check passed. Safe to proceed."
        else do
            putStrLn "[integrity] CRITICAL: Pre-check failed. Operation aborted."
            exitWith (ExitFailure 1)

-- ================================================================
-- GUARDED OPERATION
-- Wraps any C++ or HolyC operation with snapshot + watchdog
-- ================================================================

guardedOperation :: String -> Int -> IO () -> IO ()
guardedOperation label timeoutSecs operation = do
    putStrLn $ "[integrity] Guarding: " ++ label
    before <- takeSnapshot
    result <- withWatchdog timeoutSecs label (operation >> return (OK label))
    after  <- takeSnapshot
    let diffs = compareSnapshot before after
    diffOk <- mapM evalResult diffs
    opOk   <- evalResult result
    if opOk && and diffOk
        then putStrLn $ "[integrity] " ++ label ++ " completed safely."
        else do
            putStrLn $ "[integrity] CRITICAL: " ++ label ++ " caused unexpected changes."
            exitWith (ExitFailure 1)

-- ================================================================
-- POST-OPERATION CHECK
-- Called by C++ after each operation
-- ================================================================

postCheck :: IO ()
postCheck = do
    putStrLn "[integrity] Post-operation check..."
    results <- sequence [verifyLSM, verifyABAC, verifyVTA]
    allOk   <- mapM evalResult results
    if and allOk
        then putStrLn "[integrity] Post-check passed."
        else do
            putStrLn "[integrity] CRITICAL: Post-check failed. System may be in unsafe state."
            exitWith (ExitFailure 1)

-- ================================================================
-- C-EXPORTED ENTRY POINTS
-- Called by C++ UI via Haskell FFI
-- ================================================================

foreign export ccall velumrec_precheck  :: IO Int
foreign export ccall velumrec_postcheck :: IO Int

velumrec_precheck :: IO Int
velumrec_precheck = do
    results <- sequence [verifyLSM, verifyABAC, verifyVTA]
    allOk   <- mapM evalResult results
    return $ if and allOk then 0 else 1

velumrec_postcheck :: IO Int
velumrec_postcheck = do
    results <- sequence [verifyLSM, verifyABAC, verifyVTA]
    allOk   <- mapM evalResult results
    return $ if and allOk then 0 else 1

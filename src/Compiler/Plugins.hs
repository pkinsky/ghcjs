{-
    Compiler plugins for GHCJS

    Since GHCJS is a cross-compiler, it cannot execute the code that it
    generates directly into its own process.

    We can get around this for Template Haskell and GHCJSi by running the
    code with an external interpreter. It is possible to do this relatively
    efficiently because the code can only access a specific subset of GHC's
    data through a small and well-defined API: The Quasi typeclass hides
    the implementation.

    Plugins on the other hand, can see much more, and the external
    interpreter approach would require expensive serialization and
    synchronisation. Fortunately, plugins are usually relatively self-contained,
    so we use another approach:

    When a plugin is needed, GHCJS finds the closest match of the
    corresponding package in the GHC package database and loads that
    instead. The package still needs to be installed in the GHCJS package
    db. The plugin implementation would likely require some conditional
    compilation because much of the GHC API doesn't exist on ghcjs_HOST_OS.

    Since our tools don't yet know about compilers that use packages for
    multiple architectures at the same time, matching the package is done
    in a rather roundabout way, and it's likely to change in the future.

    GHC Package Environment:

       - The file `ghc_libdir` in the GHCJS library directory contains the full
         path of a GHC library directory. The GHC version must be the same as
         the one that GHCJS was compiled with. This location is used for the
         global package db.

       - If the user package db is visible, GHCJS will use GHC's user package
         db for plugins.

       - For custom package db locations, for example in a Cabal sandbox, the
         GHCJS target triplet is replaced by the triplet for the underlying
         GHC.

    Package Matching:

    When a plugin module is specified, GHCJS first finds the package with this
    module in its own package environment. Once the package id is known,
    GHCJS tries to find the closest match among the visible GHC packages,
    trying in this order:

        1. package-id (exact match with the same unit id)
        2. package (exact version number match)

    A package does not match if it doesn't have the same version number.

 -}

module Compiler.Plugins where

import DynFlags
import HscTypes
import Id
import Module
import Name
import Packages
import Type
import Outputable
import HscMain
import Panic
import GHCi
import FastString
import Linker
import DynamicLoading hiding (getValueSafely, getHValueSafely)
import GHCi.RemoteTypes
import qualified SysTools
import System.FilePath
import Compiler.Settings
import Data.Char (isSpace)
import Data.List
import Data.Maybe

import Control.Concurrent.MVar

import qualified Compiler.Info as Info

import LoadIface
import RdrName
import SrcLoc
import TcRnMonad

getValueSafely :: DynFlags -> GhcjsEnv
               -> HscEnv -> Name -> Type -> IO (Maybe a)
getValueSafely orig_dflags js_env hsc_env val_name expected_type = do
  mb_hval <- getHValueSafely orig_dflags js_env hsc_env val_name expected_type
  case mb_hval of
    Nothing   -> return Nothing
    Just hval -> do
      value <- lessUnsafeCoerce dflags "getValueSafely" hval
      -- let value = unsafeCoerce hval
      return (Just value)
  where
    dflags = hsc_dflags hsc_env

getHValueSafely :: DynFlags -> GhcjsEnv
                -> HscEnv -> Name -> Type -> IO (Maybe HValue)
getHValueSafely orig_dflags js_env hsc_env orig_name expected_type = do
  -- initialize the GHC package environment
  plugins_env <- modifyMVar (pluginState js_env) (initPluginsEnv orig_dflags)

  let dflags = hsc_dflags plugins_env
      doc    = text "contains a name used in an invocation of getHValueSafely"
  val_name0 <- remapName hsc_env plugins_env orig_name

  -- We now have an intermediate name that has the correct unit id for the GHC
  -- package, but it still has the GHCJS unique. Here we load the interface
  -- file and then find the the actual GHC name in the module exports.
  let mod    = nameModule val_name0
  (_, Just val_iface) <- initTcInteractive plugins_env $ initIfaceTcRn $ loadPluginInterface doc mod
  let mod_name = moduleName mod
      rdr_name = mkRdrUnqual (nameOccName val_name0)
      decl_spec = ImpDeclSpec { is_mod = mod_name, is_as = mod_name
                              , is_qual = False, is_dloc = noSrcSpan }
      imp_spec = ImpSpec decl_spec ImpAll
      env = mkGlobalRdrEnv (gresFromAvails (Just imp_spec) (mi_exports val_iface))
      val_name = case lookupGRE_RdrName rdr_name env of
                   [gre] -> gre_name gre
                   _     -> panic "lookupRdrNameInModule"

  -- Now look up the names for the value and type constructor in the type environment
  mb_val_thing <- lookupTypeHscEnv plugins_env val_name
  case mb_val_thing of
    Nothing -> throwCmdLineErrorS dflags (missingTyThingErrorGHC val_name)
    Just (AnId id) -> do
        -- Check the value type in the interface against the type recovered from the type constructor
        -- before finally casting the value to the type we assume corresponds to that constructor
        if expected_type `eqType` idType id
          then do
            -- Link in the module that contains the value, if it has such a module
            case nameModule_maybe val_name of
              Just mod -> do linkModule plugins_env mod
                             return ()
              Nothing ->  return ()
            -- Find the value that we just linked in and cast it given that we have proved its type
            hval <- getHValue plugins_env val_name >>= wormhole dflags
            return (Just hval)
          else return Nothing
    Just val_thing -> throwCmdLineErrorS dflags (wrongTyThingError val_name val_thing)

remapName :: HscEnv -> HscEnv -> Name -> IO Name
remapName src_env tgt_env val_name
  | Just m <- nameModule_maybe val_name =
    case remapUnit sdf tdf (moduleName m) (moduleUnitId m) of
      Nothing         ->
        throwCmdLineErrorS (hsc_dflags tgt_env) $ missingTyThingErrorGHC val_name
      Just tgt_unitid ->
        let new_m = mkModule tgt_unitid (moduleName m)
        in  pure $ mkExternalName (nameUnique val_name) new_m
                                  (nameOccName val_name) (nameSrcSpan val_name)
  | otherwise = pure val_name
  where
    sdf = hsc_dflags src_env
    tdf = hsc_dflags tgt_env

remapUnit :: DynFlags
          -> DynFlags
          -> ModuleName
          -> UnitId
          -> Maybe UnitId
remapUnit src_dflags tgt_dflags module_name unit
  -- first try package with same unit id if possible
  | Just _ <- lookupPackage tgt_dflags unit = Just unit
  -- if we're building the package, then we don't have a PackageConfig for it
  | unit == thisPackage tgt_dflags
  , tgt_config:_    <- searchPackageId tgt_dflags (SourcePackageId . mkFastString . unitToPkg . unitIdString $ unit)
  , Just m <- lookup module_name (instantiatedWith tgt_config) =
    Just (moduleUnitId m)
  -- otherwise look up package with same package id (e.g. foo-0.1)
  | Just src_config <- lookupPackage src_dflags unit
  , tgt_config:_    <- searchPackageId tgt_dflags (sourcePackageId src_config)
  , Just m <- lookup module_name (instantiatedWith tgt_config)
  = Just (moduleUnitId m)
    -- Just (unitId tgt_config)
  | otherwise = Nothing

initPluginsEnv :: DynFlags -> Maybe HscEnv -> IO (Maybe HscEnv, HscEnv)
initPluginsEnv _ (Just env) = pure (Just env, env)
initPluginsEnv orig_dflags _ = do
  let trim = let f = reverse . dropWhile isSpace in f . f
  ghcTopDir   <- readFile (topDir orig_dflags </> "ghc_libdir")
  ghcSettings <- SysTools.initSysTools (Just $ trim ghcTopDir)
  let removeJsPrefix xs = fromMaybe xs (stripPrefix "js_" xs)
      dflags0 = orig_dflags { settings = ghcSettings }
      dflags1 = gopt_unset dflags0 Opt_HideAllPackages
      dflags2 = updateWays $
         dflags1 { packageFlags  = [] -- filterPackageFlags (packageFlags dflags1)
                 -- , extraPkgConfs = filterPackageConfs . extraPkgConfs dflags1
                 , packageDBFlags = filterPackageDBFlags . packageDBFlags $ dflags1
                 , ways          = filter (/= WayCustom "js") (ways dflags1)
                 , hiSuf         = removeJsPrefix (hiSuf dflags1)
                 , dynHiSuf      = removeJsPrefix (dynHiSuf dflags1)
                 }
  dflags3 <- initDynFlags dflags2
  (dflags, units) <- initPackages dflags3
  env <- newHscEnv dflags
  pure (Just env, env)

{-
Ignore package flags for now and. Perhaps we will need to restore this at
some point for module renaming.

filterPackageFlags :: [PackageFlag] -> [PackageFlag]
filterPackageFlags = map fixPkg
  where
    fixPkg (ExposePackage xs (UnitIdArg uid) mr)
      = let pkg = unitToPkg uid
            xs' = "-package " ++ pkg
        in  ExposePackage xs' (PackageArg pkg) mr
    fixPkg x = x
-}

unitToPkg :: String -> String
unitToPkg xs
  | ('-':ys) <- dropWhile (/='-') (reverse xs) = reverse ys
  | otherwise                                  = xs

filterPackageDBFlags :: [PackageDBFlag] -> [PackageDBFlag]
filterPackageDBFlags = mapMaybe f
  where
    f (PackageDB pcr) = PackageDB <$> filterPackageConfs pcr
    f x               = Just x


filterPackageConfs :: PkgConfRef -> Maybe PkgConfRef -- [PkgConfRef] -> [PkgConfRef]
filterPackageConfs = fixPkgConf -- mapMaybe fixPkgConf
  where
    dtu '.' = '_'
    dtu x   = x
    ghcjsConf = "-ghcjs-" ++ Info.getCompilerVersion ++
                "-ghc" ++ map dtu Info.getGhcCompilerVersion ++
                "-packages.conf.d"
    ghcConf   = "-ghc-" ++ Info.getGhcCompilerVersion ++
                "-packages.conf.d"
    fixPkgConf (PkgConfFile file)
      | ghcjsConf `isSuffixOf` file = Just (PkgConfFile $
          (reverse . drop (length ghcjsConf) . reverse $ file) ++ ghcConf)
      | "package.conf.inplace" `isSuffixOf` file = Nothing
    fixPkgConf x = Just x


wrongTyThingError :: Name -> TyThing -> SDoc
wrongTyThingError name got_thing = hsep [text "The name", ppr name, ptext (sLit "is not that of a value but rather a"), pprTyThingCategory got_thing]

missingTyThingError :: Name -> SDoc
missingTyThingError name = hsep [text "The name", ppr name, ptext (sLit "is not in the type environment: are you sure it exists?")]

missingTyThingErrorGHC :: Name -> SDoc
missingTyThingErrorGHC name = hsep [text "The name", ppr name, ptext (sLit "is not in the GHC type environment: are you sure it exists?")]

throwCmdLineErrorS :: DynFlags -> SDoc -> IO a
throwCmdLineErrorS dflags = throwCmdLineError . showSDoc dflags

throwCmdLineError :: String -> IO a
throwCmdLineError = throwGhcExceptionIO . CmdLineError

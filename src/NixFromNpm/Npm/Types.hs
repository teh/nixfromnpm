{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module NixFromNpm.Npm.Types (
    module NixFromNpm.Npm.Version,
    PackageInfo(..), PackageMeta(..), VersionInfo(..),
    DistInfo(..), ResolvedPkg(..), DependencyType(..),
    BrokenPackageReason(..), ResolvedDependency(..),
    Shasum(..)
  ) where

import qualified ClassyPrelude as CP
import Data.Aeson
import Data.Aeson.Types (Parser, typeMismatch)
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T

import Data.SemVer
import Data.SemVer.Parser

import NixFromNpm.Common
import NixFromNpm.Git.Types (getObject, getDict, GithubError)
import NixFromNpm.Npm.Version
import NixFromNpm.Npm.Version.Parser
import NixFromNpm.PackageMap

-- | Package information; specifically all of the different versions.
data PackageInfo = PackageInfo {
  piVersions :: HashMap SemVer VersionInfo,
  piTags :: Record SemVer
  } deriving (Show, Eq)

-- | Metadata about a package.
data PackageMeta = PackageMeta {
  pmDescription :: Maybe Text,
  pmAuthor :: Maybe Text,
  pmHomepage :: Maybe URI,
  pmKeywords :: Vector Text
  } deriving (Show, Eq)

-- | Expresses all of the information that a version of a package needs, in
-- the abstract (e.g. using version ranges instead of explicit versions).
-- This type can be used as an input to the NpmLookup stuff to produce a
-- `ResolvedPkg`.
data VersionInfo = VersionInfo {
  viDependencies :: Record NpmVersionRange,
  viPeerDependencies :: Record NpmVersionRange,
  viOptionalDependencies :: Record NpmVersionRange,
  viDevDependencies :: Record NpmVersionRange,
  viBundledDependencies :: [Text],
  viDist :: Maybe DistInfo, -- not present if in a package.json file.
  viMain :: Maybe Text,
  viName :: Text,
  viMeta :: PackageMeta,
  viVersion :: SemVer
  } deriving (Show, Eq)

-- | SHA digest, combining an algorithm type with a digest.
data Shasum = SHA1 Text | SHA256 Text deriving (Show, Eq)

-- | Distribution info from NPM. Tells us the URL and hash of a tarball.
data DistInfo = DistInfo {
  diUrl :: Text,
  diShasum :: Shasum
  } deriving (Show, Eq)

-- | This contains the same information as the .nix file that corresponds
-- to the package. More or less it tells us everything that we need to build
-- the package.
data ResolvedPkg = ResolvedPkg {
  rpName :: Name,
  rpVersion :: SemVer,
  rpDistInfo :: Maybe DistInfo,
  rpMeta :: PackageMeta,
  rpDependencies :: Record ResolvedDependency,
  rpPeerDependencies :: Record ResolvedDependency,
  rpOptionalDependencies :: Record ResolvedDependency,
  rpDevDependencies :: Maybe (Record ResolvedDependency)
  } deriving (Show, Eq)

-- | Flag for different types of dependencies.
data DependencyType
  = Dependency    -- ^ Required at runtime.
  | PeerDependency
  | OptionalDependency
  | DevDependency -- ^ Only required for development.
  deriving (Show, Eq)

-- | Reasons why an expression might not have been able to be built.
data BrokenPackageReason
  = NoMatchingPackage Name
  | NoMatchingVersion NpmVersionRange
  | InvalidNpmVersionRange Text
  | NoSuchTag Name
  | TagPointsToInvalidVersion Name SemVer
  | InvalidSemVerSyntax Text String
  | InvalidPackageJson Text String
  | NoDistributionInfo
  | Reason String
  | GithubError GithubError
  | NotYetImplemented String
  | UnsatisfiedDependency Name -- This should never happen, but in case
  | BrokenDependency Name BrokenPackageReason
  deriving (Show, Eq, Typeable)

instance Exception BrokenPackageReason

-- | We might not be able to resolve a dependency, in which case we record
-- it as a broken package.
data ResolvedDependency
  = Resolved SemVer -- ^ Package has been resolved at this version.
  | Broken BrokenPackageReason -- ^ Could not build the dependency.
  deriving (Show, Eq)

instance Semigroup PackageInfo where
  PackageInfo vs ts <> PackageInfo vs' ts' =
    PackageInfo (vs CP.<> vs') (ts CP.<> ts')

instance Monoid PackageInfo where
  mempty = PackageInfo mempty mempty
  mappend = (CP.<>)

instance FromJSON VersionInfo where
  parseJSON = getObject "version info" >=> \o -> do
    dependencies' <- getDict "dependencies" o
    devDependencies <- getDict "devDependencies" o
    peerDependencies <- getDict "peerDependencies" o
    optionalDependencies <- getDict "optionalDependencies" o
    bundledDependencies <- o .:? "bundledDependencies" .!= []
    -- Loop through the bundled dependencies. If any of them are missing
    -- from the dependencies record, add it here.
    let isMissingDep name = not $ H.member name dependencies'
        missing = filter isMissingDep bundledDependencies
        missingDependencies = zip missing (repeat $ SemVerRange anyVersion)
        dependencies = dependencies' <> H.fromList missingDependencies
    dist <- o .:? "dist"
    name <- o .: "name"
    main <- o .:? "main"
    version <- o .: "version"
    packageMeta <- do
      let getString = \case {String s -> Just s; _ -> Nothing}
      description <- o .:? "description"
      author <- o .:? "author" <|> pure Nothing
      homepage <- o .:? "homepage" >>= \case
        Nothing -> return Nothing
        Just (String txt) -> return $ parseURIText txt
        Just (Array stuff) -> case toList $ catMaybes (getString <$> stuff) of
          [] -> return Nothing
          (uri:_) -> return $ parseURIText uri
      let
        -- If keywords are a string, split on commas and strip whitespace.
        getKeywords (String s) = fromList $ T.strip <$> T.split (==',') s
        -- If an array, just take the array.
        getKeywords (Array a) = catMaybes $ map getString a
        -- Otherwise, this is an error, but just return an empty array.
        getKeywords _ = mempty
      keywords <- map getKeywords $ o .:? "keywords" .!= Null
      return $ PackageMeta description author homepage keywords
    scripts :: Record Value <- getDict "scripts" o <|> fail "couldn't get scripts"
    case parseSemVer version of
      Left err -> throw $ VersionSyntaxError version err
      Right semver -> return $ VersionInfo {
        viDependencies = dependencies,
        viDevDependencies = devDependencies,
        viPeerDependencies = peerDependencies,
        viOptionalDependencies = optionalDependencies,
        viBundledDependencies = bundledDependencies,
        viDist = dist,
        viMain = main,
        viName = name,
        viMeta = packageMeta,
        viVersion = semver
      }

instance FromJSON SemVerRange where
  parseJSON v = case v of
    String s -> case parseSemVerRange s of
      Left err -> typeMismatch ("valid semantic version (got " <> show v <> ")") v
      Right range -> return range
    _ -> typeMismatch "string" v

instance FromJSON PackageInfo where
  parseJSON = getObject "package info" >=> \o -> do
    vs' <- getDict "versions" o
    tags' <- getDict "dist-tags" o
    let vs = H.fromList $ map (\vi -> (viVersion vi, vi)) $ H.elems vs'
        convert tags [] = return $ PackageInfo vs (H.fromList tags)
        convert tags ((tName, tVer):ts) = case parseSemVer tVer of
          Left err -> failC ["Tag ", tName, " refers to an invalid ",
                             "semver string ", tVer, ": ", pshow err]
          Right ver -> convert ((tName, ver):tags) ts
    convert [] $ H.toList tags'


instance FromJSON DistInfo where
  parseJSON = getObject "dist info" >=> \o -> do
    tarball <- o .: "tarball"
    shasum <- SHA1 <$> o .: "shasum"
    return $ DistInfo tarball shasum

patchIfMatches :: (a -> Bool) -- ^ Predicate function
               -> (a -> a) -- ^ Modification function
               -> a -- ^ Input object
               -> a -- ^ Patched object
patchIfMatches pred mod input | pred input = mod input
                              | otherwise  = input
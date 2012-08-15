--------------------------------------------------------------------------------
-- | This is the module which binds it all together
module Hakyll.Core.Run
    ( run
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative            (Applicative, (<$>))
import           Control.DeepSeq                (deepseq)
import           Control.Monad                  (filterM, foldM_, forM_)
import           Control.Monad.Error            (ErrorT, runErrorT, throwError)
import           Control.Monad.Reader           (ReaderT, ask, runReaderT)
import           Control.Monad.State            (StateT, evalStateT, get, put)
import           Control.Monad.Trans            (liftIO)
import           Data.Map                       (Map)
import qualified Data.Map                       as M
import           Data.Maybe                     (fromMaybe)
import           Data.Monoid                    (mappend, mempty)
import           Data.Set                       (Set)
import qualified Data.Set                       as S
import           Prelude                        hiding (reverse)
import           System.FilePath                ((</>))


--------------------------------------------------------------------------------
import           Hakyll.Core.Compile
import           Hakyll.Core.Compiler
import           Hakyll.Core.Compiler.Internal
import           Hakyll.Core.Compiler.Store
import           Hakyll.Core.Configuration
import           Hakyll.Core.DependencyAnalyzer
import           Hakyll.Core.DirectedGraph
import           Hakyll.Core.Identifier
import           Hakyll.Core.Item
import           Hakyll.Core.Logger
import           Hakyll.Core.Populate
import           Hakyll.Core.Resource
import           Hakyll.Core.Resource.Provider
import qualified Hakyll.Core.Resource.Provider  as Provider
import           Hakyll.Core.Route
import           Hakyll.Core.Store              (Store)
import qualified Hakyll.Core.Store              as Store
import           Hakyll.Core.Util.File
import           Hakyll.Core.Writable


--------------------------------------------------------------------------------
type Compilation i = Map ItemIdentifier (SomeItem, i, Compile i)


--------------------------------------------------------------------------------
-- | Run all rules needed, return the rule set used
run :: HakyllConfiguration
    -> Populate i
    -> (i -> Compile i)
    -> (i -> Route)
    -> IO ()
run configuration populate compile' route' = do
    logger <- makeLogger putStrLn

    section logger "Initialising"
    store <- timed logger "Creating store" $
        Store.new (inMemoryCache configuration) $ storeDirectory configuration
    provider <- timed logger "Creating resource provider" $
        Provider.new (ignoreFile configuration) "."

    -- Populate
    pop <- timed logger "Populating..." $ runPopulate populate provider
    let comp = M.fromList $ flip map pop $
            \(id', (item, ud)) -> (id', (item, ud, compile' ud))

    (todo, modified) <- order logger store provider pop comp

    foldM_
        (build configuration logger store provider pop comp route' modified)
        M.empty todo


--------------------------------------------------------------------------------
order :: Logger -> Store -> ResourceProvider -> Population i -> Compilation i
      -> IO ([ItemIdentifier], (ItemIdentifier -> Bool))
order logger store provider population compilation = do
    -- Fetch the old graph from the store
    mgraph <- Store.get store ["Hakyll.Core.Run.order", "dependencies"]
    let (oldGraph, firstRun) = case mgraph of
            Nothing -> (mempty, True)
            Just g  -> (g, False)

    let _ = oldGraph :: DirectedGraph ItemIdentifier

    -- Build new dependency graph
    let newGraph  = fromList depsList
        compilers = M.toList compilation
        items     = populationItems population
        depsList  = flip map compilers $ \(id', (_, _, Compile compiler)) ->
            (id', runCompilerDependencies compiler population)

    -- Store the new graph, but make sure the old graph is fully evaluated
    -- first, because if it's not, the store file might still be open.
    oldGraph `deepseq`
        Store.set store ["Hakyll.Core.Run.order", "dependencies"] newGraph

    -- For each item that has a resource, check whether it has been modified
    modified <- flip filterM items $ \(SomeItem i) -> case itemResource i of
        Nothing -> return False
        Just rs -> liftIO $ resourceModified provider store rs
    let modifiedSet = S.fromList $ map someItemIdentifier modified
        isModified  = if firstRun then const True else (`S.member` modifiedSet)

    -- Detect cycles in the graph
    case findCycle newGraph of
        Just c  -> dumpCycle logger c >> fail "herp"  -- TODO
        Nothing -> return $
            (analyze oldGraph newGraph isModified, isModified)


--------------------------------------------------------------------------------
-- | Dump cycle error and quit
dumpCycle :: Logger -> [ItemIdentifier] -> IO ()
dumpCycle logger cycle' = do
    section logger "Dependency cycle detected! Conflict:"
    forM_ (zip cycle' $ drop 1 cycle') $ \(x, y) ->
        report logger $ show x ++ " -> " ++ show y


--------------------------------------------------------------------------------
build :: HakyllConfiguration
      -> Logger
      -> Store
      -> ResourceProvider
      -> Population i
      -> Compilation i
      -> (i -> Route)
      -> (ItemIdentifier -> Bool)
      -> Map ItemIdentifier FilePath
      -> ItemIdentifier
      -> IO (Map ItemIdentifier FilePath)
build config logger store provider pop comp route' modified routes id' = do
    section logger $ "Building " ++ id'


    r <- runCompiler compiler pop someItem provider (`M.lookup` routes)
        store (modified id') logger

    case r of
        Left err      -> fail err   -- TODO
        Right (Box x) -> do
            mroute <- runRoute (route' userdata) dir x
            section logger $ show mroute
            return $ maybe routes (\r -> M.insert id' r routes) mroute
  where
    (someItem, userdata, Compile compiler) = comp M.! id'
    dir = destinationDirectory config
{-
    let ruleSet = runRules rules provider
        compilers = rulesCompilers ruleSet

        -- Extract the reader/state
        reader = unRuntime $ addNewCompilers compilers
        stateT = runReaderT reader $ RuntimeEnvironment
                    { hakyllLogger           = logger
                    , hakyllConfiguration    = configuration
                    , hakyllRoutes           = rulesRoutes ruleSet
                    , hakyllResourceProvider = provider
                    , hakyllStore            = store
                    , hakyllFirstRun         = firstRun
                    }

    -- Run the program and fetch the resulting state
    result <- runErrorT $ runStateT stateT $ RuntimeState
        { hakyllAnalyzer  = makeDependencyAnalyzer mempty (const False) oldGraph
        , hakyllCompilers = M.empty
        }

    case result of
        Left e             ->
            thrown logger e
        Right ((), state') ->
            -- We want to save the final dependency graph for the next run
            Store.set store ["Hakyll.Core.Run.run", "dependencies"] $
                analyzerGraph $ hakyllAnalyzer state'

    -- Flush and return
    flushLogger logger
    return ruleSet
-- | Add a number of compilers and continue using these compilers
--
addNewCompilers :: [(Identifier (), Compiler () CompileRule)]
                -- ^ Compilers to add
                -> Runtime ()
addNewCompilers newCompilers = Runtime $ do
    -- Get some information
    logger <- hakyllLogger <$> ask
    section logger "Adding new compilers"
    provider <- hakyllResourceProvider <$> ask
    store <- hakyllStore <$> ask
    firstRun <- hakyllFirstRun <$> ask

    -- Old state information
    oldCompilers <- hakyllCompilers <$> get
    oldAnalyzer <- hakyllAnalyzer <$> get

    let -- All known compilers
        universe = M.keys oldCompilers ++ map fst newCompilers

        -- Create a new partial dependency graph
        dependencies = flip map newCompilers $ \(id', compiler) ->
            let deps = runCompilerDependencies compiler id' universe
            in (id', deps)

        -- Create the dependency graph
        newGraph = fromList dependencies

    -- Check which items have been modified
    modified <- fmap S.fromList $ flip filterM (map fst newCompilers) $
        liftIO . resourceModified provider store . fromIdentifier
    let checkModified = if firstRun then const True else (`S.member` modified)

    -- Create a new analyzer and append it to the currect one
    let newAnalyzer = makeDependencyAnalyzer newGraph checkModified $
            analyzerPreviousGraph oldAnalyzer
        analyzer = mappend oldAnalyzer newAnalyzer

    -- Update the state
    put $ RuntimeState
        { hakyllAnalyzer  = analyzer
        , hakyllCompilers = M.union oldCompilers (M.fromList newCompilers)
        }

    -- Continue
    unRuntime stepAnalyzer

stepAnalyzer :: Runtime ()
stepAnalyzer = Runtime $ do
    -- Step the analyzer
    state <- get
    let (signal, analyzer') = step $ hakyllAnalyzer state
    put $ state { hakyllAnalyzer = analyzer' }

    case signal of Done      -> return ()
                   Cycle c   -> unRuntime $ dumpCycle c
                   Build id' -> unRuntime $ build id'

-- | Dump cyclic error and quit
--
dumpCycle :: [Identifier ()] -> Runtime ()
dumpCycle cycle' = Runtime $ do
    logger <- hakyllLogger <$> ask
    section logger "Dependency cycle detected! Conflict:"
    forM_ (zip cycle' $ drop 1 cycle') $ \(x, y) ->
        report logger $ show x ++ " -> " ++ show y

build :: Identifier () -> Runtime ()
build id' = Runtime $ do
    logger <- hakyllLogger <$> ask
    routes <- hakyllRoutes <$> ask
    provider <- hakyllResourceProvider <$> ask
    store <- hakyllStore <$> ask
    compilers <- hakyllCompilers <$> get

    section logger $ "Compiling " ++ show id'

    -- Fetch the right compiler from the map
    let compiler = compilers M.! id'

    -- Check if the resource was modified
    isModified <- liftIO $ resourceModified provider store $ fromIdentifier id'

    -- Run the compiler
    result <- timed logger "Total compile time" $ liftIO $
        runCompiler compiler id' provider (M.keys compilers) routes
                    store isModified logger

    case result of
        -- Compile rule for one item, easy stuff
        Right (CompileRule compiled) -> do
            case runRoutes routes id' of
                Nothing  -> return ()
                Just url -> timed logger ("Routing to " ++ url) $ do
                    destination <-
                        destinationDirectory . hakyllConfiguration <$> ask
                    let path = destination </> url
                    liftIO $ makeDirectories path
                    liftIO $ write path compiled

            -- Continue for the remaining compilers
            unRuntime stepAnalyzer

        -- Metacompiler, slightly more complicated
        Right (MetaCompileRule newCompilers) ->
            -- Actually I was just kidding, it's not hard at all
            unRuntime $ addNewCompilers newCompilers

        -- Some error happened, rethrow in Runtime monad
        Left err -> throwError err
-}

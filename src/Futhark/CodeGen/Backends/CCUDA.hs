{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}
module Futhark.CodeGen.Backends.CCUDA
  ( compileProg
  , GC.CParts(..)
  , GC.asLibrary
  , GC.asExecutable
  ) where

import qualified Language.C.Quote.OpenCL as C
import Data.List

import qualified Futhark.CodeGen.Backends.GenericC as GC
import qualified Futhark.CodeGen.ImpGen.CUDA as ImpGen
import Futhark.Error
import Futhark.Representation.ExplicitMemory hiding (GetSize, CmpSizeLe, GetSizeMax)
import Futhark.MonadFreshNames
import Futhark.CodeGen.ImpCode.OpenCL
import Futhark.CodeGen.Backends.CCUDA.Boilerplate
import Futhark.CodeGen.Backends.GenericC.Options

import Data.Maybe (catMaybes)

compileProg :: MonadFreshNames m => Prog ExplicitMemory -> m (Either InternalError GC.CParts)
compileProg prog = do
  res <- ImpGen.compileProg prog
  case res of
    Left err -> return $ Left err
    Right (Program cuda_code cuda_prelude kernel_names _ sizes prog') ->
      let extra = generateBoilerplate cuda_code cuda_prelude
                                      kernel_names sizes
      in Right <$> GC.compileProg operations extra cuda_includes
                   [Space "device", Space "local", DefaultSpace] cliOptions prog'
  where
    operations :: GC.Operations OpenCL ()
    operations = GC.Operations
                 { GC.opsWriteScalar = writeCUDAScalar
                 , GC.opsReadScalar  = readCUDAScalar
                 , GC.opsAllocate    = allocateCUDABuffer
                 , GC.opsDeallocate  = deallocateCUDABuffer
                 , GC.opsCopy        = copyCUDAMemory
                 , GC.opsStaticArray = staticCUDAArray
                 , GC.opsMemoryType  = cudaMemoryType
                 , GC.opsCompiler    = callKernel
                 , GC.opsFatMemory   = True
                 }
    cuda_includes = unlines [ "#include <cuda.h>"
                            , "#include <nvrtc.h>"
                            ]

cliOptions :: [Option]
cliOptions = [ Option { optionLongName = "dump-cuda"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [C.cstm|futhark_context_config_dump_program_to(cfg, optarg);|]
                      }
             , Option { optionLongName = "load-cuda"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [C.cstm|futhark_context_config_load_program_from(cfg, optarg);|]
                      }
             , Option { optionLongName = "dump-ptx"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [C.cstm|futhark_context_config_dump_ptx_to(cfg, optarg);|]
                      }
             , Option { optionLongName = "load-ptx"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [C.cstm|futhark_context_config_load_ptx_from(cfg, optarg);|]
                      }
             , Option { optionLongName = "print-sizes"
                      , optionShortName = Nothing
                      , optionArgument = NoArgument
                      , optionAction = [C.cstm|{
                          int n = futhark_get_num_sizes();
                          for (int i = 0; i < n; i++) {
                            printf("%s (%s)\n", futhark_get_size_name(i),
                                                futhark_get_size_class(i));
                          }
                          exit(0);
                        }|]
                      }
             ]

writeCUDAScalar :: GC.WriteScalar OpenCL ()
writeCUDAScalar mem idx t "device" _ val = do
  val' <- newVName "write_tmp"
  GC.stm [C.cstm|{$ty:t $id:val' = $exp:val;
                  CUDA_SUCCEED(
                    cuMemcpyHtoD($exp:mem + $exp:idx,
                                 &$id:val',
                                 sizeof($ty:t)));
                 }|]
writeCUDAScalar _ _ _ space _ _ =
  fail $ "Cannot write to '" ++ space ++ "' memory space."

readCUDAScalar :: GC.ReadScalar OpenCL ()
readCUDAScalar mem idx t "device" _ = do
  val <- newVName "read_res"
  GC.decl [C.cdecl|$ty:t $id:val;|]
  GC.stm [C.cstm|CUDA_SUCCEED(
                   cuMemcpyDtoH(&$id:val,
                                $exp:mem + $exp:idx,
                                sizeof($ty:t)));
                |]
  return [C.cexp|$id:val|]
readCUDAScalar _ _ _ space _ =
  fail $ "Cannot write to '" ++ space ++ "' memory space."

allocateCUDABuffer :: GC.Allocate OpenCL ()
allocateCUDABuffer mem size tag "device" =
  GC.stm [C.cstm|CUDA_SUCCEED(cuda_alloc(&ctx->cuda, $exp:size, $exp:tag, &$exp:mem));|]
allocateCUDABuffer _ _ _ "local" = return ()
allocateCUDABuffer _ _ _ space =
  fail $ "Cannot allocate in '" ++ space ++ "' memory space."

deallocateCUDABuffer :: GC.Deallocate OpenCL ()
deallocateCUDABuffer mem tag "device" =
  GC.stm [C.cstm|CUDA_SUCCEED(cuda_free(&ctx->cuda, $exp:mem, $exp:tag));|]
deallocateCUDABuffer _ _ "local" = return ()
deallocateCUDABuffer _ _ space =
  fail $ "Cannot deallocate in '" ++ space ++ "' memory space."

copyCUDAMemory :: GC.Copy OpenCL ()
copyCUDAMemory dstmem dstidx dstSpace srcmem srcidx srcSpace nbytes = do
  fn <- memcpyFun dstSpace srcSpace
  GC.stm [C.cstm|CUDA_SUCCEED(
                  $id:fn($exp:dstmem + $exp:dstidx,
                         $exp:srcmem + $exp:srcidx,
                         $exp:nbytes));
                |]
  where
    memcpyFun DefaultSpace (Space "device")     = return "cuMemcpyDtoH"
    memcpyFun (Space "device") DefaultSpace     = return "cuMemcpyHtoD"
    memcpyFun (Space "device") (Space "device") = return "cuMemcpy"
    memcpyFun _ _ = fail $ "Cannot copy to '" ++ show dstSpace
                           ++ "' from '" ++ show srcSpace ++ "'."

staticCUDAArray :: GC.StaticArray OpenCL ()
staticCUDAArray name "device" t vals = do
  let ct = GC.primTypeToCType t
      vals' = [[C.cinit|$exp:v|] | v <- map GC.compilePrimValue vals]
      num_elems = length vals
  name_realtype <- newVName $ baseString name ++ "_realtype"
  GC.libDecl [C.cedecl|static $ty:ct $id:name_realtype[$int:num_elems] = {$inits:vals'};|]
  -- Fake a memory block.
  GC.contextField (pretty name) [C.cty|struct memblock_device|] Nothing
  -- During startup, copy the data to where we need it.
  GC.atInit [C.cstm|{
    ctx->$id:name.references = NULL;
    ctx->$id:name.size = 0;
    CUDA_SUCCEED(cuMemAlloc(&ctx->$id:name.mem,
                            ($int:num_elems > 0 ? $int:num_elems : 1)*sizeof($ty:ct)));
    if ($int:num_elems > 0) {
      CUDA_SUCCEED(cuMemcpyHtoD(ctx->$id:name.mem, $id:name_realtype,
                                $int:num_elems*sizeof($ty:ct)));
    }
  }|]
  GC.item [C.citem|struct memblock_device $id:name = ctx->$id:name;|]
staticCUDAArray _ space _ _ =
  fail $ "CUDA backend cannot create static array in '" ++ space
          ++ "' memory space"

cudaMemoryType :: GC.MemoryType OpenCL ()
cudaMemoryType "device" = return [C.cty|typename CUdeviceptr|]
cudaMemoryType "local" = pure [C.cty|unsigned char|] -- dummy type
cudaMemoryType space =
  fail $ "CUDA backend does not support '" ++ space ++ "' memory space."

callKernel :: GC.OpCompiler OpenCL ()
callKernel (HostCode c) = GC.compileCode c
callKernel (GetSize v key) =
  GC.stm [C.cstm|$id:v = ctx->sizes.$id:key;|]
callKernel (CmpSizeLe v key x) = do
  x' <- GC.compileExp x
  GC.stm [C.cstm|$id:v = ctx->sizes.$id:key <= $exp:x';|]
callKernel (GetSizeMax v size_class) =
  let field = "max_" ++ cudaSizeClass size_class
  in GC.stm [C.cstm|$id:v = ctx->cuda.$id:field;|]
  where
    cudaSizeClass (SizeThreshold _) = "threshold"
    cudaSizeClass SizeGroup = "block_size"
    cudaSizeClass SizeNumGroups = "grid_size"
    cudaSizeClass SizeTile = "tile_size"
callKernel (LaunchKernel name args num_blocks block_size) = do
  args_arr <- newVName "kernel_args"
  time_start <- newVName "time_start"
  time_end <- newVName "time_end"
  (args', shared_vars) <- unzip <$> mapM mkArgs args
  let (shared_sizes, shared_offsets) = unzip $ catMaybes shared_vars
      shared_offsets_sc = mkOffsets shared_sizes
      shared_args = zip shared_offsets shared_offsets_sc
      shared_tot = last shared_offsets_sc
  mapM_ (\(arg,offset) ->
           GC.decl [C.cdecl|unsigned int $id:arg = $exp:offset;|]
        ) shared_args

  (grid_x, grid_y, grid_z) <- mkDims <$> mapM GC.compileExp num_blocks
  (block_x, block_y, block_z) <- mkDims <$> mapM GC.compileExp block_size
  let args'' = [ [C.cinit|&$id:a|] | a <- args' ]
      sizes_nonzero = expsNotZero [grid_x, grid_y, grid_z,
                      block_x, block_y, block_z]
  GC.stm [C.cstm|
    if ($exp:sizes_nonzero) {
      void *$id:args_arr[] = {$inits:args''};
      typename int64_t $id:time_start = 0, $id:time_end = 0;
      if (ctx->debugging) {
        fprintf(stderr, "Launching %s with grid size (", $string:name);
        $stms:(printSizes [grid_x, grid_y, grid_z])
        fprintf(stderr, ") and block size (");
        $stms:(printSizes [block_x, block_y, block_z])
        fprintf(stderr, ").\n");
        $id:time_start = get_wall_time();
      }
      CUDA_SUCCEED(
        cuLaunchKernel(ctx->$id:name,
                       $exp:grid_x, $exp:grid_y, $exp:grid_z,
                       $exp:block_x, $exp:block_y, $exp:block_z,
                       $exp:shared_tot, NULL,
                       $id:args_arr, NULL));
      if (ctx->debugging) {
        CUDA_SUCCEED(cuCtxSynchronize());
        $id:time_end = get_wall_time();
        fprintf(stderr, "Kernel %s runtime: %ldus\n",
                $string:name, $id:time_end - $id:time_start);
      }
    }|]
  where
    mkDims [] = ([C.cexp|0|] , [C.cexp|0|], [C.cexp|0|])
    mkDims [x] = (x, [C.cexp|1|], [C.cexp|1|])
    mkDims [x,y] = (x, y, [C.cexp|1|])
    mkDims (x:y:z:_) = (x, y, z)
    addExp x y = [C.cexp|$exp:x + $exp:y|]
    alignExp e = [C.cexp|$exp:e + ((8 - ($exp:e % 8)) % 8)|]
    mkOffsets = scanl (\a b -> a `addExp` alignExp b) [C.cexp|0|]
    expNotZero e = [C.cexp|$exp:e != 0|]
    expAnd a b = [C.cexp|$exp:a && $exp:b|]
    expsNotZero = foldl expAnd [C.cexp|1|] . map expNotZero
    mkArgs (ValueKArg e t) =
      (,Nothing) <$> GC.compileExpToName "kernel_arg" t e
    mkArgs (MemKArg v) = do
      v' <- GC.rawMem v
      arg <- newVName "kernel_arg"
      GC.decl [C.cdecl|typename CUdeviceptr $id:arg = $exp:v';|]
      return (arg, Nothing)
    mkArgs (SharedMemoryKArg (Count c)) = do
      num_bytes <- GC.compileExp c
      size <- newVName "shared_size"
      offset <- newVName "shared_offset"
      GC.decl [C.cdecl|unsigned int $id:size = $exp:num_bytes;|]
      return (offset, Just (size, offset))

    printSizes =
      intercalate [[C.cstm|fprintf(stderr, ", ");|]] . map printSize
    printSize e =
      [[C.cstm|fprintf(stderr, "%zu", $exp:e);|]]

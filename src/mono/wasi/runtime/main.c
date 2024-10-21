﻿#include <stdbool.h>
#include <string.h>
#include <driver.h>
#include <mono/metadata/assembly.h>

// This symbol's implementation is generated during the build
const char* dotnet_wasi_getentrypointassemblyname();
char *monoeg_g_getenv(const char *variable);

#ifdef WASI_AFTER_RUNTIME_LOADED_DECLARATIONS
// This is supplied from the MSBuild itemgroup @(WasiAfterRuntimeLoaded)
WASI_AFTER_RUNTIME_LOADED_DECLARATIONS
#endif

#ifdef WASM_LIBRARY_MODE
// _initialize is a function generated by the WASI SDK libc that calls the LLVM synthesized __wasm_call_ctors function for reactor components:
// https://github.com/WebAssembly/wasi-libc/blob/9f51a7102085ec6a6ced5778f0864c9af9f50000/libc-bottom-half/crt/crt1-reactor.c#L7-L27
// We define and call it for WASM_LIBRARY_MODE and TARGET_WASI to call all the global c++ static constructors.  This ensures the runtime is initialized
// when calling into WebAssembly Component Model components.
extern void _initialize();

// CustomNativeMain programs are built using the same libbootstrapperdll as WASM_LIBRARY_MODE but wasi-libc will not provide an _initialize implementation,
// so create a dummy one here and make it weak to allow wasi-libc to provide the real implementation for WASI reactor components.
__attribute__((weak)) void _initialize()
{
}

// Guard the "_initialize" call so that well-behaving hosts do not get affected by this workaround.
static bool g_CalledInitialize = false;

__attribute__((constructor))
void WasiInitializationFlag() {
   *(volatile bool*)&g_CalledInitialize = true;
}

static bool runtime_initialized = false;

#endif

int initialize_runtime()
{
#if defined(WASM_LIBRARY_MODE)
    if (runtime_initialized)
		return 0;
	if (!g_CalledInitialize)
		_initialize();
	runtime_initialized = true;
#endif

#ifndef WASM_SINGLE_FILE
	mono_set_assemblies_path("managed");
#endif
	mono_wasm_load_runtime(0);

#ifdef WASI_AFTER_RUNTIME_LOADED_CALLS
	// This is supplied from the MSBuild itemgroup @(WasiAfterRuntimeLoaded)
	WASI_AFTER_RUNTIME_LOADED_CALLS
#endif
	return 0;
}

#ifndef WASM_LIBRARY_MODE
int main(int argc, char * argv[]) {
    int initval = initialize_runtime();
    if (initval != 0)
        return initval;
	int arg_ofs = 0;
#ifdef WASM_SINGLE_FILE
	/*
	 * For single-file bundle, running with wasmtime:
	 *
	 *  $ wasmtime run --dir . MainAssembly.wasm [args]
	 *
	 * arg0: MainAssembly
	 * arg1-..: args
	 */
	const char* assembly_name = dotnet_wasi_getentrypointassemblyname();
	MonoAssembly* assembly = mono_assembly_open(assembly_name, NULL);
#else
	/*
	 * For default case which uses dotnet.wasm, running with wasmtime:
	 *
	 *  $ wasmtime run --dir . dotnet.wasm MainAssembly [args]
	 *
	 * arg0: dotnet.wasm
	 * arg1: MainAssembly
	 * arg2-..: args
	 */

	const char *assembly_name = argv[1];
	arg_ofs = 1;
	MonoAssembly* assembly = mono_wasm_assembly_load (assembly_name);
	if (!assembly) {
		printf("Could not load assembly %s\n", assembly_name);
		return 1;
	}
#endif

	MonoMethod* entry_method = mono_wasi_assembly_get_entry_point (assembly);
	if (!entry_method) {
		fprintf(stderr, "Could not find entrypoint in assembly %s\n", assembly_name);
		exit(1);
	}

	MonoObject* out_exc;
	MonoObject* out_res;
	// Managed app will see: arg0: MainAssembly, arg1-.. [args]
	int ret = mono_runtime_run_main(entry_method, argc - arg_ofs, &argv[arg_ofs], &out_exc);
	if (out_exc)
	{
		mono_print_unhandled_exception(out_exc);
		exit(1);
	}
	ret = ret < 0 ? -ret : ret;

	// until WASI can work with unix exit code https://github.com/WebAssembly/wasi-cli/pull/44
	char* dotnet_wasi_print_exit_code = monoeg_g_getenv ("DOTNET_WASI_PRINT_EXIT_CODE");
	if (ret != 0 && dotnet_wasi_print_exit_code && strcmp(dotnet_wasi_print_exit_code, "1") == 0)
	{
		fprintf(stderr, "WASM EXIT %d\n", ret);
	}

	return ret;
}
#endif

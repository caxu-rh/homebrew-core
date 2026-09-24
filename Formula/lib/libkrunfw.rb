class Libkrunfw < Formula
  include Language::Python::Virtualenv

  desc "Dynamic library bundling the guest payload consumed by libkrun"
  homepage "https://github.com/libkrun/libkrunfw"
  url "https://github.com/libkrun/libkrunfw/archive/refs/tags/v5.6.1.tar.gz"
  sha256 "b8ec9f2205f1092a5fcd8ab8ecb8e1a939dea15bb842d844da99c5a062e3f453"
  license "LGPL-2.1-only"

  depends_on "python@3.14" => :build
  depends_on "xz" => :build

  uses_from_macos "bc" => :build
  uses_from_macos "bison" => :build
  uses_from_macos "flex" => :build

  on_macos do
    depends_on "gnu-sed" => :build
    depends_on "gnu-tar" => :build
    depends_on "libelf" => :build
    depends_on "lld" => :build
    depends_on "llvm" => :build
    depends_on "make" => :build

    fails_with :clang
  end

  resource "kernel" do
    url "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.109.tar.xz", using: :nounzip
    sha256 "5484e552a334e15019f4aeba89e5b58f04651cf2f4e24e04de9f152f1c38e3fa"
  end

  resource "pyelftools" do
    url "https://files.pythonhosted.org/packages/a3/11/767522582afab1b884d277de0e6e011640cb9d7292a38694b4b1a1df1ae8/pyelftools-0.33.tar.gz"
    sha256 "660d82dcbeb8e83d1702bd97f223f761625da06111c0cc988eac6b8ab0c1b61f"
  end

  patch do
    url "https://github.com/caxu-rh/libkrunfw/commit/972eb4605b88f23170361b119d54677b189c72cd.patch?full_index=1"
    sha256 "ae6af14408aa8dd624522a8ea7f303ee54e888d8113939f906560a64182b5f3e"
    type :backport
  end

  deny_network_access! [:postinstall, :test]

  def install
    ENV.prepend_path "PATH", Formula["gnu-sed"].libexec/"gnubin" if OS.mac?
    ENV.prepend_path "PATH", Formula["gnu-tar"].libexec/"gnubin" if OS.mac?

    kernel_version = resource("kernel").version
    mkdir_p buildpath/"tarballs"
    resource("kernel").stage buildpath/"tarballs"

    make_args = []
    make_args << "MACOS_BUILDER=native" if OS.mac?

    # Extract and configure the kernel source tree.
    cross_compile_args = %W[
      KERNEL_CC=#{formula_opt_bin("llvm")}/clang
      KERNEL_LD=#{formula_opt_bin("lld")}/ld.lld
      KERNEL_AR=#{formula_opt_bin("llvm")}/llvm-ar
      KERNEL_NM=#{formula_opt_bin("llvm")}/llvm-nm
      KERNEL_OBJCOPY=#{formula_opt_bin("llvm")}/llvm-objcopy
      KERNEL_OBJDUMP=#{formula_opt_bin("llvm")}/llvm-objdump
      KERNEL_STRIP=#{formula_opt_bin("llvm")}/llvm-strip
      KERNEL_READELF=#{formula_opt_bin("llvm")}/llvm-readelf
    ]
    system "make", "linux-#{kernel_version}", *make_args, *cross_compile_args

    kernel_binary = if Hardware::CPU.arm64?
      "linux-#{kernel_version}/arch/arm64/boot/Image"
    else
      "linux-#{kernel_version}/vmlinux"
    end

    # The crypto/jitterentropy.o object needs to be built without optimizations,
    # which is hindered by Homebrew's compiler shims. On macOS, this is worked
    # around by us pointing `make` to directly use brewed llvm; on Linux, we build
    # the kernel first, then rebuild the affected object without optimizations,
    # and then re-link the kernel once more with the rebuilt object.
    if OS.linux?
      source_file = "linux-#{kernel_version}/crypto/jitterentropy.c"
      inreplace source_file, "#error \"The CPU Jitter", "#warning \"The CPU Jitter"
      system "make", kernel_binary, *make_args, *cross_compile_args

      inreplace source_file, "#warning \"The CPU Jitter", "#error \"The CPU Jitter"
      rm "linux-#{kernel_version}/crypto/jitterentropy.o"
      ENV.O0 { system "make", "-C", "linux-#{kernel_version}", "crypto/jitterentropy.o" }
      rm kernel_binary
    end

    system "make", kernel_binary, *make_args, *cross_compile_args

    # Generate the C bundle and compile the dylib (using host toolchain configuration)
    python_version = Language::Python.major_minor_version python3
    venv = virtualenv_create(buildpath/"venv", "python#{python_version}")
    venv.pip_install resource("pyelftools")
    ENV.prepend_path "PYTHONPATH", venv.site_packages
    ENV.prepend_path "PATH", venv.root/"bin"

    system "make", *make_args

    # Install to `lib` subdir instead of upstream default `lib64`
    make_install_args = make_args
    make_install_args += "LIBDIR_Linux=lib" if OS.linux?
    system "make", "install", "PREFIX=#{prefix}", *make_install_args
  end

  test do
    # Verify the dylib is loadable and exports the expected symbol.
    (testpath/"test.c").write <<~C
      #include <dlfcn.h>
      #include <stdio.h>
      #include <stdlib.h>

      int main(void) {
        void *handle = dlopen("#{lib}/libkrunfw.dylib", RTLD_LAZY);
        if (!handle) {
          fprintf(stderr, "dlopen: %s\\n", dlerror());
          return 1;
        }
        void *sym = dlsym(handle, "krunfw_get_kernel");
        if (!sym) {
          fprintf(stderr, "dlsym: %s\\n", dlerror());
          dlclose(handle);
          return 1;
        }
        printf("krunfw_get_kernel found at %p\\n", sym);
        dlclose(handle);
        return 0;
      }
    C
    system ENV.cc, "test.c", "-o", "test"
    system "./test"
  end
end

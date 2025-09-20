# Makefile do port GCC (realista)

PORTNAME=        gcc
VERSION=         12.2.0
CATEGORY=        lang
MAINTAINER=      ports@example.org
COMMENT=         GNU Compiler Collection
LICENSE=         GPL-3.0

MASTER_SITES=    https://ftp.gnu.org/gnu/gcc/gcc-$(VERSION)/ \
                 https://mirrors.kernel.org/gnu/gcc/gcc-$(VERSION)/
DISTFILES=       gcc-$(VERSION).tar.xz \
                 gmp-6.2.1.tar.xz \
                 mpfr-4.1.0.tar.xz \
                 mpc-1.2.1.tar.gz \
                 isl-0.24.tar.xz

MASTER_SITES+=   https://ftp.gnu.org/gnu/gmp/ \
                 https://ftp.gnu.org/gnu/mpfr/ \
                 https://ftp.gnu.org/gnu/mpc/ \
                 https://libisl.sourceforge.io/

DEPENDS=         gmp mpfr mpc isl

WRKSRC=          $(WORKDIR)/$(PORTNAME)-$(VERSION)
BUILDDIR=        $(WRKSRC)/build

CONFIGURE_ARGS=  --disable-multilib \
                 --enable-languages=c,c++ \
                 --with-system-zlib \
                 --with-gmp=$(PREFIX) \
                 --with-mpfr=$(PREFIX) \
                 --with-mpc=$(PREFIX) \
                 --with-isl=$(PREFIX)

# Hooks (executam comandos diretos)
pre-configure:
	mkdir -p $(BUILDDIR)

do-configure:
	cd $(BUILDDIR) && ../configure $(CONFIGURE_ARGS)

do-build:
	cd $(BUILDDIR) && $(MAKE)

do-check:
	cd $(BUILDDIR) && $(MAKE) -k check

do-install:
	cd $(BUILDDIR) && $(MAKE) install DESTDIR=$(DESTDIR)

post-install:
	echo ">> GCC $(VERSION) instalado com sucesso em $(PREFIX)"

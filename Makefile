TARGET?=	NETBSD
ARCH?=		amd64
NETVERS?=	10
NETDIST=	https://nycdn.netbsd.org/pub/NetBSD-daily/netbsd-${NETVERS}/latest/${ARCH}/binary
KDIST=		${NETDIST}
ALPVERS?=	3.21.0
#ALPDIST=	https://dl-cdn.alpinelinux.org/alpine/v${ALPVERS%.*}/releases/${ARCH}
ALPDIST=	https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${ARCH}

WHOAMI!=	whoami
USER!= 		id -un
GROUP!= 	id -gn
ifneq (${WHOAMI}, root)
SUDO!=		command -v doas || echo "sudo -E ARCH=${ARCH} NETVERS=${NETVERS}"
endif
SETSEXT=	tar.xz
SETSDIR=	sets/${ARCH}

ifeq (${ARCH}, evbarm-aarch64)
KERNEL=		netbsd-GENERIC64.img
LIVEIMGGZ=	https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/evbarm-aarch64/binary/gzimg/arm64.img.gz
else ifeq (${ARCH}, i386)
KERNEL=		netbsd-SMOL386
KDIST=		https://smolbsd.org/assets
SETSEXT=	tgz
else
KERNEL=		netbsd-SMOL
KDIST=		https://smolbsd.org/assets
LIVEIMGGZ=	https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/images/NetBSD-10.99.12-amd64-live.img.gz
endif
LIVEIMG=	NetBSD-${ARCH}-live.img

# sets to fetch
RESCUE=		rescue.${SETSEXT} etc.${SETSEXT}
BASE=		base.${SETSEXT} etc.${SETSEXT}
PROF=		${BASE} comp.${SETSEXT}
NBAKERY=	${BASE} comp.${SETSEXT}
BOZO=		${BASE}
IMGBUILDER=	${BASE}

# Alpine rootfs / iso to fetch
ALPINE_ROOTFS=alpine-minirootfs-${ALPVERS}-${ARCH}.tar.gz
ALPINE_ISO=alpine-virt-${ALPVERS}-${ARCH}.iso
ALPINE= 	${ALPINE_ROOTFS} ${ALPINE_VIRT}

ifeq ($(shell uname -m), x86_64)
ROOTFS?=       -r ld0a
else
# unknown / aarch64
ROOTFS?=       -r ld5a
endif

ifeq (${TARGET}, ALPINE)
ROOTFS?=	-r vda
endif

# any BSD variant including MacOS
DDUNIT=		m
ifeq ($(shell uname), Linux)
DDUNIT=		M
endif

# guest root filesystem will be read-only
ifeq (${MOUNTRO}, y)
EXTRAS+=	-o
endif
# extra remote script
ifneq (${CURLSH},)
EXTRAS+=	-c ${CURLSH}
endif

# default memory amount for a guest
MEM?=		256
# default port redirect, gives network to the guest
PORT?=		::22022-:22
# default size for disk built by imgbuilder
SVCSZ?=		128

SERVICE?=	$@
IMGSIZE?=	512

kernfetch:
	@echo "fetching ${KERNEL}"
	@[ -f ${KERNEL} ] || ( \
		[ "${ARCH}" = "amd64" -o "${ARCH}" = "i386" ] && \
			curl -L -O ${KDIST}/${KERNEL} || \
			curl -L -o- ${KDIST}/kernel/${KERNEL}.gz | \
				gzip -dc > ${KERNEL} \
	)

setfetch:
	@echo "fetching sets"
	[ -d ${SETSDIR} ] || mkdir -p ${SETSDIR}
	for s in ${SETS}; do \
		if [ ! -f ${SETSDIR}/$$s ]; then \
			curl -L -o ${SETSDIR}/$$s ${NETDIST}/sets/$$s; \
		fi; \
	done

alpinefetch:
	@echo "fetching Alpine"
	[ -d ${SETSDIR} ] || mkdir -p ${SETSDIR}
	for s in ${SETS}; do \
		if [ ! -f ${SETSDIR}/$$s ]; then \
			curl -L -o ${SETSDIR}/$$s ${ALPDIST}/$$s; \
		fi; \
	done

alpine:
	$(MAKE) alpinefetch SETS="${ALPINE_ROOTFS} ${ALPINE_ISO}"
	${SUDO} ./mkimg.sh -t ${SERVICE} -i ${SERVICE}-${ARCH}.img -s ${SERVICE} \
		-m 20 -x "${ALPINE_ROOTFS}" -z "${ALPINE_ISO}" ${EXTRAS} 
	${SUDO} chown ${USER}:${GROUP} $@-${ARCH}.img

rescue:
	$(MAKE) setfetch SETS="${RESCUE}"
	${SUDO} ./mkimg.sh -m 20 -x "${RESCUE}" ${EXTRAS}
	${SUDO} chown ${USER}:${GROUP} $@-${ARCH}.img

base:
	$(MAKE) setfetch SETS="${BASE}"
	${SUDO} ./mkimg.sh -i ${SERVICE}-${ARCH}.img -s ${SERVICE} \
		-m ${IMGSIZE} -x "${BASE}" ${EXTRAS}
	${SUDO} chown ${USER}:${GROUP} ${SERVICE}-${ARCH}.img

prof:
	$(MAKE) setfetch SETS="${PROF}"
	${SUDO} ./mkimg.sh -i $@-${ARCH}.img -s $@ -m 1024 -k ${KERNEL} -x "${PROF}" \
		${EXTRAS}
	${SUDO} chown ${WHOAMI} $@-${ARCH}.img

nbakery:
	$(MAKE) setfetch SETS="${NBAKERY}"
	${SUDO} ./mkimg.sh -i $@-${ARCH}.img -s $@ -m 2048 -x "${NBAKERY}" ${EXTRAS}
	${SUDO} chown ${USER}:${GROUP} $@-${ARCH}.img

imgbuilder:
	$(MAKE) setfetch SETS="${BASE}"
	# build the building image if ${NOIMGBUILDERBUILD} is not defined
	if [ -z "${NOIMGBUILDERBUILD}" ]; then \
		${SUDO} SVCIMG=${SVCIMG} ./mkimg.sh -i $@-${ARCH}.img -s $@ \
			-m 512 -x "${BASE}" ${EXTRAS} && \
		${SUDO} chown ${USER}:${GROUP} $@-${ARCH}.img; \
	fi
	# now start an imgbuilder microvm and build the actual service
	# image unless $NOSVCIMGBUILD is set (probably a GL pipeline)
	if [ -z "${NOSVCIMGBUILD}" ]; then \
		dd if=/dev/zero of=${SVCIMG}-${ARCH}.img bs=1${DDUNIT} count=${SVCSZ}; \
		./startnb.sh -k ${KERNEL} -i $@-${ARCH}.img -a '-v' \
			-h ${SVCIMG}-${ARCH}.img -p ${PORT} ${ROOTFS} -m ${MEM}; \
	fi

live:	kernfetch
	@echo "fetching ${LIVEIMG}"
	@[ -f ${LIVEIMG} ] || curl -o- -L ${LIVEIMGGZ}|gzip -dc > ${LIVEIMG}

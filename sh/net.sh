#!/sbin/runscript
# Copyright 2007-2008 Roy Marples <roy@marples.name>
# All rights reserved. Released under the 2-clause BSD license.

MODULESDIR="${RC_LIBDIR}/net"
MODULESLIST="${RC_SVCDIR}/nettree"
_config_vars="config routes"

[ -z "${IN_BACKGROUND}" ] && IN_BACKGROUND="NO"

description="Configures network interfaces."

# Handy var so we don't have to embed new lines everywhere for array splitting
__IFS="
"
depend()
{
	local IFACE=${SVCNAME#*.}
	local IFVAR=$(shell_var "${IFACE}")

	need localmount
	after bootmisc
	provide net
	case "${IFACE}" in
		lo|lo0);;
		*)
			after net.lo net.lo0
			if type depend_${IFVAR} >/dev/null 2>&1; then
				depend_${IFVAR}
			fi
			local prov=
			eval prov=\$RC_NEED_${IFVAR}
			[ -n "${prov}" ] && need ${prov}
			eval prov=\$RC_USE_${IFVAR}
			[ -n "${prov}" ] && use ${prov}
			eval prov=\$RC_BEFORE_${IFVAR}
			[ -n "${prov}" ] && before ${prov}
			eval prov=\$RC_AFTER_${IFVAR}
			[ -n "${prov}" ] && after ${prov}
			eval prov=\$RC_PROVIDE_${IFVAR}
			[ -n "${prov}" ] && provide ${prov}
			;;
	esac
}

# Support bash arrays - sigh
_get_array()
{
	local _a=
	if [ -n "${BASH}" ]; then
		case "$(declare -p "$1" 2>/dev/null)" in
			"declare -a "*)
				eval "set -- \"\${$1[@]}\""
				for _a; do
					printf "%s\n" "${_a}"
				done
				return 0
				;;
		esac
	fi

	eval _a=\$$1
	printf "%s" "${_a}"
	printf "\n"
	[ -n "${_a}" ]
}

# Flatten bash arrays to simple strings
_flatten_array()
{
	if [ -n "${BASH}" ]; then
		case "$(declare -p "$1" 2>/dev/null)" in
			"declare -a "*)
				eval "set -- \"\${$1[@]}\""
				for x; do
					printf "'%s' " "$(printf "$x" | sed "s:':'\\\'':g")"
				done
				return 0
				;;
		esac
	fi

	eval _a=\$$1
	printf "%s" "${_a}"
	printf "\n"
	[ -n "${_a}" ]
}

_wait_for_carrier()
{
	local timeout= efunc=einfon

	_has_carrier  && return 0

	eval timeout=\$carrier_timeout_${IFVAR}
	timeout=${timeout:-${carrier_timeout:-5}}

	# Incase users don't want this nice feature ...
	[ ${timeout} -le 0 ] && return 0

	yesno ${RC_PARALLEL} && efunc=einfo
	${efunc} "Waiting for carrier (${timeout} seconds) "
	while [ ${timeout} -gt 0 ]; do
		sleep 1
		if _has_carrier; then
			[ "${efunc}" = "einfon" ] && echo
			eend 0
			return 0
		fi
		timeout=$((${timeout} - 1))
		[ "${efunc}" = "einfon" ] && printf "."
	done

	[ "${efunc}" = "einfon" ] && echo
	eend 1
	return 1
}

_netmask2cidr()
{
	# Some shells cannot handle hex arithmetic, so we massage it slightly
	# Buggy shells include FreeBSD sh, dash and busybox.
	# bash and NetBSD sh don't need this.
	case $1 in
		0x*)
		local hex=${1#0x*} quad=
		while [ -n "${hex}" ]; do
			local lastbut2=${hex#??*}
			quad=${quad}${quad:+.}0x${hex%${lastbut2}*}
			hex=${lastbut2}
		done
		set -- ${quad}
		;;
	esac

	local i= len=
	local IFS=.
	for i in $1; do
		while [ ${i} != "0" ]; do
			len=$((${len} + ${i} % 2))
			i=$((${i} >> 1))
		done
	done

	echo "${len}"
}

_configure_variables()
{
	local var= v= t=

	for var in ${_config_vars}; do
		local v=
		for t; do
			eval v=\$${var}_${t}
			if [ -n "${v}" ]; then
				eval ${var}_${IFVAR}=\$${var}_${t}
				continue 2
			fi
		done
	done
}

_show_address()
{
	einfo "received address $(_get_inet_address "${IFACE}")"
}

# Basically sorts our modules into order and saves the list
_gen_module_list()
{
	local x= f= force=$1
	if ! ${force} && [ -s "${MODULESLIST}" -a "${MODULESLIST}" -nt "${MODULESDIR}" ]; then
		local update=false
		for x in "${MODULESDIR}"/*; do
			[ -e "${x}" ] || continue
			if [ "${x}" -nt "${MODULESLIST}" ]; then
				update=true
				break
			fi
		done
		${update} || return 0
	fi

	einfo "Caching network module dependencies" 
	# Run in a subshell to protect the main script
	(
	after() {
		eval ${MODULE}_after="\"\${${MODULE}_after}\${${MODULE}_after:+ }$*\""
	}

	before() {
		local mod=${MODULE}
		local MODULE=
		for MODULE; do
			after "${mod}"
		done
	}

	program() {
		if [ "$1" = "start" -o "$1" = "stop" ]; then
			local s="$1"
			shift
			eval ${MODULE}_program_${s}="\"\${${MODULE}_program_${s}}\${${MODULE}_program_${s}:+ }$*\""
		else
			eval ${MODULE}_program="\"\${${MODULE}_program}\${${MODULE}_program:+ }$*\""
		fi
	}

	provide() {
		eval ${MODULE}_provide="\"\${${MODULE}_provide}\${${MODULE}_provide:+ }$*\""
		local x
		for x in $*; do
			eval ${x}_providedby="\"\${${MODULE}_providedby}\${${MODULE}_providedby:+ }${MODULE}\""
		done
	}

	for MODULE in "${MODULESDIR}"/*; do
		sh -n "${MODULE}" || continue
		. "${MODULE}" || continue 
		MODULE=${MODULE#${MODULESDIR}/}
		MODULE=${MODULE%.sh}
		eval ${MODULE}_depend
		MODULES="${MODULES} ${MODULE}"
	done

	VISITED=
	SORTED=
	visit() {
		case " ${VISITED} " in
			*" $1 "*) return;;
		esac
		VISITED="${VISITED} $1"

		eval AFTER=\$${1}_after
		for MODULE in ${AFTER}; do
			eval PROVIDEDBY=\$${MODULE}_providedby
			if [ -n "${PROVIDEDBY}" ]; then
				for MODULE in ${PROVIDEDBY}; do
					visit "${MODULE}"
				done
			else
				visit "${MODULE}"
			fi
		done

		eval PROVIDE=\$${1}_provide
		for MODULE in ${PROVIDE}; do
			visit "${MODULE}"
		done

		eval PROVIDEDBY=\$${1}_providedby
		[ -z "${PROVIDEDBY}" ] && SORTED="${SORTED} $1"
	}

	for MODULE in ${MODULES}; do
		visit "${MODULE}"
	done

	printf "" > "${MODULESLIST}"
	i=0
	for MODULE in ${SORTED}; do
		eval PROGRAM=\$${MODULE}_program
		eval PROGRAM_START=\$${MODULE}_program_start
		eval PROGRAM_STOP=\$${MODULE}_program_stop
		eval PROVIDE=\$${MODULE}_provide
		echo "module_${i}='${MODULE}'" >> "${MODULESLIST}"
		echo "module_${i}_program='${PROGRAM}'" >> "${MODULESLIST}"
		echo "module_${i}_program_start='${PROGRAM_START}'" >> "${MODULESLIST}"
		echo "module_${i}_program_stop='${PROGRAM_STOP}'" >> "${MODULESLIST}"
		echo "module_${i}_provide='${PROVIDE}'" >> "${MODULESLIST}"
		i=$((${i} + 1))
	done
	echo "module_${i}=" >> "${MODULESLIST}"
	)

	return 0
}

_load_modules()
{
	local starting=$1 mymods=

	# Ensure our list is up to date
	_gen_module_list false
	if ! . "${MODULESLIST}"; then
		_gen_module_list true
		. "${MODULESLIST}"
	fi

	MODULES=
	if [ "${IFACE}" != "lo" -a "${IFACE}" != "lo0" ]; then
		eval mymods=\$modules_${IFVAR}
		[ -z "${mymods}" ] && mymods=${modules}
	fi

	local i=-1 x= mod= f= provides=
	while true; do
		i=$((${i} + 1))
		eval mod=\$module_${i}
		[ -z "${mod}" ] && break
		[ -e "${MODULESDIR}/${mod}.sh" ] || continue

		eval set -- \$module_${i}_program
		if [ -n "$1" ]; then
			x=
			for x; do
				[ -x "${x}" ] && break
			done
			[ -x "${x}" ] || continue
		fi
		if ${starting}; then
			eval set -- \$module_${i}_program_start
		else
			eval set -- \$module_${i}_program_stop
		fi
		if [ -n "$1" ]; then
			x=
			for x; do
				case "${x}" in
					/*) [ -x "${x}" ] && break;;
					*) type "${x}" >/dev/null 2>&1 && break;;
				esac
				unset x
			done
			[ -n "${x}" ] || continue
		fi

		eval provides=\$module_${i}_provide
		if ${starting}; then
			case " ${mymods} " in
				*" !${mod} "*) continue;;
				*" !${provides} "*) [ -n "${provides}" ] && continue;;
			esac
		fi
		MODULES="${MODULES}${MODULES:+ }${mod}"

		# Now load and wrap our functions
		if ! . "${MODULESDIR}/${mod}.sh"; then
			eend 1 "${SVCNAME}: error loading module \`${mod}'"
			exit 1
		fi

		[ -z "${provides}" ] && continue

		# Wrap our provides
		local f=
		for f in pre_start start post_start; do 
			eval "${provides}_${f}() { type ${mod}_${f} >/dev/null 2>&1 || return 0; ${mod}_${f} \"\$@\"; }"
		done

		eval module_${mod}_provides="${provides}"
		eval module_${provides}_providedby="${mod}"
	done

	# Wrap our preferred modules
	for mod in ${mymods}; do
		case " ${MODULES} " in
			*" ${mod} "*)
			eval x=\$module_${mod}_provides
			[ -z "${x}" ] && continue
			for f in pre_start start post_start; do 
				eval "${x}_${f}() { type ${mod}_${f} >/dev/null 2>&1 || return 0; ${mod}_${f} \"\$@\"; }"
			done
			eval module_${x}_providedby="${mod}"
			;;
		esac
	done

	# Finally remove any duplicated provides from our list if we're starting
	# Otherwise reverse the list
	local LIST="${MODULES}" p=
	MODULES=
	if ${starting}; then
		for mod in ${LIST}; do
			eval x=\$module_${mod}_provides
			if [ -n "${x}" ]; then
				eval p=\$module_${x}_providedby
				[ "${mod}" != "${p}" ] && continue
			fi
			MODULES="${MODULES}${MODULES:+ }${mod}"
		done
	else
		for mod in ${LIST}; do 
			MODULES="${mod}${MODULES:+ }${MODULES}"
		done
	fi

	veinfo "Loaded modules: ${MODULES}"
}

_load_config()
{
	local config="$(_get_array "config_${IFVAR}")"
	local fallback="$(_get_array fallback_${IFVAR})"

	config_index=0
	local IFS="$__IFS"
	set -- ${config}
	
	# We should support a space separated array for cidr configs
	if [ $# = 1 ]; then
		unset IFS
		set -- ${config}
		# Of course, we may have a single address added old style.
		case "$2" in
			netmask|broadcast|brd|brd+)
				local IFS="$__IFS"
				set -- ${config}
				;;
		esac
	fi

	# Ensure that loopback has the correct address
	if [ "${IFACE}" = "lo" -o "${IFACE}" = "lo0" ]; then
		if [ "$1" != "null" ]; then
		   	config_0="127.0.0.1/8"
			config_index=1
		fi
	else	
		if [ -z "$1" ]; then
			ewarn "No configuration specified; defaulting to DHCP"
			config_0="dhcp"
			config_index=1
		fi
	fi


	# We store our config in an array like vars
	# so modules can influence it
	for cmd; do
		eval config_${config_index}="'${cmd}'"
		config_index=$((${config_index} + 1))
	done
	# Terminate the list
	eval config_${config_index}=

	config_index=0
	for cmd in ${fallback}; do
		eval fallback_${config_index}="'${cmd}'"
		config_index=$((${config_index} + 1))
	done
	# Terminate the list
	eval fallback_${config_index}=

	# Don't set to zero, so any net modules don't have to do anything extra
	config_index=-1
}

start()
{
	local IFACE=${SVCNAME#*.} oneworked=false module=
	local IFVAR=$(shell_var "${IFACE}") cmd= our_metric=
	local metric=0

	einfo "Bringing up interface ${IFACE}"
	eindent

	if [ -z "${MODULES}" ]; then
		local MODULES=
		_load_modules true
	fi

	# We up the iface twice if we have a preup to ensure it's up if
	# available in preup and afterwards incase the user inadvertently
	# brings it down
	if type preup >/dev/null 2>&1; then
		_up 2>/dev/null
		ebegin "Running preup"
		eindent
		preup || return 1
		eoutdent
	fi

	_up 2>/dev/null
	
	for module in ${MODULES}; do
		if type "${module}_pre_start" >/dev/null 2>&1; then
			${module}_pre_start || exit $?
		fi
	done

	if ! _exists; then
		eerror "ERROR: interface ${IFACE} does not exist"
		eerror "Ensure that you have loaded the correct kernel module for your hardware"
		return 1
	fi

	if ! _wait_for_carrier; then
		if service_started devd; then
			ewarn "no carrier, but devd will start us when we have one"
			mark_service_inactive "${SVCNAME}"
		else
			eerror "no carrier"
		fi
		return 1
	fi

	local config= config_index=
	_load_config
	config_index=0

	eval our_metric=\$metric_${IFVAR} 
	if [ -n "${our_metric}" ]; then
		metric=${our_metric}
	elif [ "${IFACE}" != "lo" -a "${IFACE}" != "lo0" ]; then
		metric=$((${metric} + $(_ifindex)))
	fi

	while true; do
		eval config=\$config_${config_index}
		[ -z "${config}" ] && break 

		set -- ${config}
		ebegin "$1"
		eindent
		case "$1" in
			noop)
				if [ -n "$(_get_inet_address)" ]; then
					oneworked=true
					break
				fi
				;;
			null) :;;
			[0-9]*|*:*) _add_address ${config};;
			*)
				if type "${config}_start" >/dev/null 2>&1; then
					"${config}"_start
				else
					eerror "nothing provides \`${config}'"
				fi
				;;
		esac
		if eend $?; then
			oneworked=true
		else
			eval config=\$fallback_${config_index}
			if [ -n "${config}" ]; then
				eoutdent
				ewarn "Trying fallback configuration ${config}"
				eindent
				eval config_${config_index}=\$config
				unset fallback_${config_index}
				config_index=$((${config_index} - 1))
			fi
		fi
		eoutdent
		config_index=$((${config_index} + 1))
	done

	if ! ${oneworked}; then
		if type failup >/dev/null 2>&1; then
			ebegin "Running failup"
			eindent
			failup
			eoutdent
		fi
		return 1
	fi

	local hidefirstroute=false first=true
	local routes="$(_get_array "routes_${IFVAR}")"
	if [ "${IFACE}" = "lo" -o "${IFACE}" = "lo0" ]; then
		if [ "${config_0}" != "null" ]; then
			routes="127.0.0.0/8 via 127.0.0.1
${routes}"
			hidefirstroute=true
		fi
	fi

	local OIFS="${IFS}" SIFS=${IFS-y}
	local IFS="$__IFS"
	for cmd in ${routes}; do
		unset IFS
		if ${first}; then
			first=false
			einfo "Adding routes"
		fi
		eindent
		ebegin ${cmd}
		# Work out if we're a host or a net if not told
		case ${cmd} in
			-net" "*|-host" "*);;
			*" "netmask" "*)                   cmd="-net ${cmd}";;
			*.*.*.*/32*)                       cmd="-host ${cmd}";;
			*.*.*.*/*|0.0.0.0" "*|default" "*) cmd="-net ${cmd}";;
			*)                                 cmd="-host ${cmd}";;
		esac
		if ${hidefirstroute}; then
			_add_route ${cmd} >/dev/null 2>&1
			hidefirstroute=false
		else
			_add_route ${cmd} >/dev/null
		fi
		eend $?
		eoutdent
	done
	if [ "${SIFS}" = "y" ]; then
		unset IFS
	else
		IFS="${OIFS}"
	fi

	for module in ${MODULES}; do
		if type "${module}_post_start" >/dev/null 2>&1; then
			${module}_post_start || exit $?
		fi
	done

	if type postup >/dev/null 2>&1; then
		ebegin "Running postup"
		eindent
		postup 
		eoutdent
	fi

	return 0
}

stop()
{
	local IFACE=${SVCNAME#*.} module=
	local IFVAR=$(shell_var "${IFACE}") opts=

	einfo "Bringing down interface ${IFACE}"
	eindent

	if [ -z "${MODULES}" ]; then
		local MODULES=
		_load_modules false
	fi

	if type predown >/dev/null 2>&1; then
		ebegin "Running predown"
		eindent
		predown || return 1
		eoutdent
	else
		if is_net_fs /; then
			eerror "root filesystem is network mounted -- can't stop ${IFACE}"
			return 1
		fi
	fi

	for module in ${MODULES}; do
		if type "${module}_pre_stop" >/dev/null 2>&1; then
			${module}_pre_stop || exit $?
		fi
	done

	for module in ${MODULES}; do
		if type "${module}_stop" >/dev/null 2>&1; then
			${module}_stop
		fi
	done

	# Only delete addresses for non PPP interfaces
	if ! type is_ppp >/dev/null 2>&1 || ! is_ppp; then
		_delete_addresses "${IFACE}"
	fi

	for module in ${MODULES}; do
		if type "${module}_post_stop" >/dev/null 2>&1; then
			${module}_post_stop
		fi
	done

	! yesno ${IN_BACKGROUND} && \
	[ "${IFACE}" != "lo" -a "${IFACE}" != "lo0" ] && \
	_down 2>/dev/null

	type resolvconf >/dev/null 2>&1 && resolvconf -d "${IFACE}"

	if type postdown >/dev/null 2>&1; then
		ebegin "Running postdown"
		eindent
		postdown
		eoutdent
	fi

	return 0
}

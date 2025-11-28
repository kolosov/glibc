#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   lib.sh of /tools/glibc/Library/updog
#   Description: Upgrade/Downgrade of glibc.
#   Author: Martin Coufal <mcoufal@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2022 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = updog
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 NAME

glibc/updog - Upgrade/Downgrade of Glibc

=head1 DESCRIPTION

This library helps to install desired version of glibc using packages in
/mnt/redhat/brewroot or build URL. It is based on code moved from
Install/update-downgrade-of-glibc authored by Miroslav Franc.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 VARIABLES

Below is the list of global variables.

=over

=item UPDOG_GLIBC_BUILD

Glibc build (in format: '%{name}-%{version}-%{release}') to be installed from
brewroot. Default glibc build to be used when no provided is an empty string,
resulting in abortion of upgrade/downgrade operation and notifying the user.
When updogInstall is called with the 'build' parameter, UPDOG_GLIBC_BUILD is
overridden with this value.

=cut

UPDOG_GLIBC_BUILD=${UPDOG_GLIBC_BUILD:-""}

true <<'=cut'
=item UPDOG_GLIBC_BUILD_URL

When non-zero, glibc build given by UPDOG_GLIBC_BUILD variable will be attempted
to be installed from RPMs downloaded from this URL (using 'download-packages*'
scripts). Default glibc build URL to be used when no provided is an empty
string.

=back

=cut

UPDOG_GLIBC_BUILD_URL=${UPDOG_GLIBC_BUILD_URL:-""}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 updogInstall

Compare current glibc version with build/UPDOG_GLIBC_BUILD and prepare
environment for RPM upgrade/downgrade. If everything checks out,
upgrade/downgrade of glibc package will be done.

    updogInstall [build]

=over

=item build

Optional parameter, glibc build in format: '%{name}-%{version}-%{release}'. If
left out, value in UPDOG_GLIBC_BUILD is used.

=back

Returns 0 when a new version of glibc is installed successfully, non-zero
otherwise.

=cut

updogInstall() {

    local UPDOG_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    if [ -z "${UPDOG_DIR}" ]; then
        rlFail "Can't determine the location of the updog sources!"
        return 1
    fi
    if [[ -z $1 ]]; then
        if [[ -z $UPDOG_GLIBC_BUILD ]]; then
            rlFail "No idea what to do, build NOT specified in UPDOG_GLIBC_BUILD nor as a parameter...";
            return 2
        fi
    else
        UPDOG_GLIBC_BUILD=$1
    fi
    if rlIsRHEL ">=8"
    then
        "${UPDOG_DIR}/rpmdev-vercmp3" "$UPDOG_GLIBC_BUILD" "$(rpm --qf %{name}-%{version}-%{release} -q glibc.$(arch))"
    else
        "${UPDOG_DIR}/rpmdev-vercmp" "$UPDOG_GLIBC_BUILD" "$(rpm --qf %{name}-%{version}-%{release} -q glibc.$(arch))"
    fi
    what=$?
    if test $what -eq 12; then
        OPTIONS=' -Uvh --oldpackage --replacepkgs '
    elif test $what -eq 11; then
        OPTIONS=' -Fvh '
    elif test $what -eq 0; then
        rlLogInfo "$UPDOG_GLIBC_BUILD is already installed"
        return 0
    else
        rlFail "rpmdev-vercmp can't compare versions (rc=$what)"
        return 3
    fi

    findmnt /mnt/redhat || rlMountRedhat
    rlRun "IFS=- read -r glibc_name glibc_version glibc_release _ <<<\"$UPDOG_GLIBC_BUILD\""
    # If the caller passed a Build URL, we get the packages from there,
    # otherwise (almost always the case) we expect the packages in Brew
    if [[ -n "$UPDOG_GLIBC_BUILD_URL" ]]; then
        rlRun "mkdir -p $(arch)"
        rlRun "rm -f $(arch)/*"
        rlRun "pushd $(arch)"
        if rlIsRHEL ">=8"
        then
            rlRun "\"${UPDOG_DIR}/download-packages3\" \"$UPDOG_GLIBC_BUILD_URL\""
        else
            rlRun "\"${UPDOG_DIR}/download-packages\" \"$UPDOG_GLIBC_BUILD_URL\""
        fi
        rlRun "popd"
    else
        rlRun "pushd /mnt/redhat/brewroot/packages/glibc/${glibc_version}/${glibc_release}/"
    fi
    rlLog "--- installed ---"
    rlLog "$(updog_print_glibc)"
    rlLog "--- --------- ---"
    debuginfos="$(updog_print_debuginfos)"
    if test "x" != "x$debuginfos"; then
        rlRun "yum -y remove $(echo $debuginfos)"
    fi
    packages=""
    for p in $(updog_print_glibc); do
        vrold=$(rpm --qf "%{version}-%{release}\n" -q $p)
        #workaround for draft build
        vrnew="${glibc_version}-${glibc_release%,draft*}"
        pp="$(echo $p | sed s/$vrold/$vrnew/)"
        packages="$packages $(echo $pp | rev | cut -d. -f1 | rev)/$pp.rpm"
    done; unset p
    rlRun "ls $packages" || rlFail "Oh crap! Some package seems to be missing!"
    rlRun "rpm $OPTIONS $packages"
    res=$?
    if test "x" != "x$debuginfos"; then
        rlRun "rpm -Uvh \$(find \$(arch) -name \*debuginfo\*)"
        res=$(($res || $?))
    fi
    rlLog "--- installed ---"
    rlLog "$(updog_print_glibc)"
    rlLog "--- --------- ---"
    if [[ -z "$UPDOG_GLIBC_BUILD_URL" ]]; then
        rlRun "popd"
    else
        rlRun "rm -rf $(arch)/"
    fi
    return $res
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Local helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

updog_print_glibc()
{
    rpm --qf "%{name}-%{version}-%{release}.%{arch}\n" -qa | grep -iE "^(glibc|nscd|nss_db|nptl-devel|glibc-nss-devel|nss_hesiod|libnsl-)" | grep -v kernheaders | grep -v tools
}

updog_print_debuginfos()
{
    updog_print_glibc | grep debuginfo
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.

updogLibraryLoaded () {
    if rlIsRHEL 7
    then
        PACKAGES=(glibc glibc-common glibc-headers glibc-devel glibc-utils nscd curl gd rpm-python python binutils)
    else
        PACKAGES=(glibc glibc-common curl)
        rlRun "yum -y install python3"
    fi
    for p in "${PACKAGES[@]}"; do
        if ! rpm -q $p --quiet; then
            rlRun "yum -y install $p"
        fi
        rlAssertRpm "$p"
    done; unset p
    return 0
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Martin Coufal <mcoufal@redhat.com>

=back

=cut

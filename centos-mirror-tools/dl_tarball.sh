#!/usr/bin/env bash

#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019 Intel Corporation
#

# The build of StarlingX relies, besides RPM Binaries and Sources, in this
# repository which is a collection of packages in the form of Tar Compressed
# files and 3 RPMs obtained from a Tar Compressed file. This script and a text
# file containing a list of packages enable their download and the creation
# of the repository based in common and specific requirements dictated
# by the StarlingX building system recipes.

# input files:
# The file tarball-dl.lst contains the list of packages and artifacts for
# building this sub-mirror.
tarball_file=""

set -x
DL_TARBALL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" )" )"

source $DL_TARBALL_DIR/url_utils.sh
source $DL_TARBALL_DIR/utils.sh

usage () {
    echo "$0 [-D <distro>] [-s|-S|-u|-U] [-h] <path_to_tarball_dl.lst>"
}

# Permitted values of dl_source
dl_from_stx_mirror="stx_mirror"
dl_from_upstream="upstream"
dl_from_stx_then_upstream="$dl_from_stx_mirror $dl_from_upstream"
dl_from_upstream_then_stx="$dl_from_upstream $dl_from_stx_mirror"

# Download from what source?
#   dl_from_stx_mirror = StarlingX mirror only
#   dl_from_upstream   = Original upstream source only
#   dl_from_stx_then_upstream = Either source, STX prefered (default)"
#   dl_from_upstream_then_stx = Either source, UPSTREAM prefered"
dl_source="$dl_from_stx_then_upstream"
dl_flag=""

distro="centos"

MULTIPLE_DL_FLAG_ERROR_MSG="Error: Please use only one of: -s,-S,-u,-U"

multiple_dl_flag_check () {
    if [ "$dl_flag" != "" ]; then
        echo "$MULTIPLE_DL_FLAG_ERROR_MSG"
        usage
        exit 1
    fi
}

# Parse out optional arguments
while getopts "D:hsSuU" o; do
    case "${o}" in
        D)
            distro="${OPTARG}"
            ;;

        s)
            # Download from StarlingX mirror only. Do not use upstream sources.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_mirror"
            dl_flag="-s"
            ;;
        S)
            # Download from StarlingX mirror only. Do not use upstream sources.
            multiple_dl_flag_check
            dl_source="$dl_from_stx_then_upstream"
            dl_flag="-S"
            ;;
        u)
            # Download from upstream only. Do not use StarlingX mirror.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream"
            dl_flag="-u"
            ;;
        U)
            # Download from upstream only. Do not use StarlingX mirror.
            multiple_dl_flag_check
            dl_source="$dl_from_upstream_then_stx"
            dl_flag="-U"
            ;;
        h)
            # Help
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))
tarball_file="${1}"
shift


if [ ! -e $tarball_file ]; then
    echo "$tarball_file does not exist, please have a check!"
    exit -1
fi

# The 2 categories we can divide the list of packages in the output directory:
# - General hosted under "downloads" output directory.
# - Puppet hosted under "downloads/puppet" output directory.
# to be populated under $MY_REPO/downloads/puppet

export DL_MIRROR_LOG_DIR="${DL_MIRROR_LOG_DIR:-./logs}"
export DL_MIRROR_OUTPUT_DIR="${DL_MIRROR_OUTPUT_DIR:-./output/stx/CentOS}"

logs_dir="${DL_MIRROR_LOG_DIR}"
output_log="$logs_dir/log_download_tarball_missing.txt"
output_path="${DL_MIRROR_OUTPUT_DIR}"
output_tarball=$output_path/downloads
output_puppet=$output_tarball/puppet

mkdir -p $output_tarball
mkdir -p $output_puppet
if [ ! -d "$logs_dir" ]; then
    mkdir "$logs_dir"
fi

cat /dev/null > $output_log

is_tarball() {
    local tarball_name="$1"
    local mime_type
    local types=("gzip" "x-bzip2" "x-rpm" "x-xz" "x-gzip" "x-tar")
    local FOUND=1

    mime_type=$(file --mime-type -b $tarball_name | cut -d "/" -f 2)
    for t in "${types[@]}"; do
        if [ "$mime_type" == "$t" ]; then
            FOUND=0
            break;
        fi
    done
    return $FOUND
}

# Download function using curl or similar command

download_package() {
    local tarball_name="$1"
    local upstream_url="$2"
    local stx_url=""
    local url=""
    local rc=1

    stx_url="$(url_to_stx_mirror_url "$upstream_url" "$distro")"

    for dl_src in $dl_source; do
        case $dl_src in
            $dl_from_stx_mirror)
                url="$stx_url"
                ;;
            $dl_from_upstream)
                url="$upstream_url"
                ;;
            *)
                echo "Error: Unknown dl_source '$dl_src'"
                continue
                ;;
        esac

        url_exists "$url"
        if [ $? != 0 ]; then
            echo "Warning: '$url' is broken"
        else
            download_file --quiet "$url" "$tarball_name"
            if [ $? -eq 0 ]; then
                if is_tarball "$tarball_name"; then
                    echo "Ok: $download_path"
                    rc=0
                    break
                else
                    echo "Warning: File from '$url' is not a tarball"
                    \rm "$tarball_name"
                    rc=1
                fi
            else
                echo "Warning: failed to download '$url'"
                continue
            fi
        fi
    done

    if [ $rc != 0 ]; then
        echo "Error: failed to download '$upstream_url'"
        echo "$upstream_url" > "$output_log"
    fi

    return $rc
}

# This script will iterate over the tarball.lst text file and execute specific
# tasks based on the name of the package:

error_count=0;

for line in $(cat $tarball_file); do

    # A line from the text file starting with "#" character is ignored

    if [[ "$line" =~ ^'#' ]]; then
        echo "Skip $line"
        continue
    fi

    # The text file contains 3 columns separated by a character "#"
    # - Column 1, name of package including extensions as it is referenced
    #   by the build system recipe, character "!" at the beginning of the name package
    #   denotes special handling is required tarball_name=`echo $line | cut -d"#" -f1-1`
    # - Column 2, name of the directory path after it is decompressed as it is
    #   referenced in the build system recipe.
    # - Column 3, the URL for the file or git to download
    # - Column 4, download method, one of
    #             http - download a simple file
    #             http_filelist - download multiple files by appending a list of subpaths
    #                             to the base url.  Tar up the lot.
    #             http_script - download a simple file, run script whos output is a tarball
    #             git - download a git, checkout branch and tar it up
    #             git_script - download a git, checkout branch, run script whos output is a tarball
    #
    # - Column 5, utility field
    #             If method is git or git_script, this is a branch,tag,sha we need to checkout
    #             If method is http_filelist, this is the path to a file containing subpaths.
    #                 Subpaths are appended to the urls and downloaded.
    #             Otherwise unused
    # - Column 6, Path to script.
    #             Not yet supported.
    #             Intent is to run this script to produce the final tarball, replacing
    #             all the special case code currently embedded in this script.

    tarball_name=$(echo $line | cut -d"#" -f1-1)
    directory_name=$(echo $line | cut -d"#" -f2-2)
    tarball_url=$(echo $line | cut -d"#" -f3-3)
    method=$(echo $line | cut -d"#" -f4-4)
    util=$(echo $line | cut -d"#" -f5-5)
    script=$(echo $line | cut -d"#" -f6-6)

    # Remove leading '!' if present
    tarball_name="${tarball_name//!/}"

    # - For the General category and the Puppet category:
    #   - Packages have a common process: download, decompressed,
    #     change the directory path and compressed.

    if [[ "$line" =~ ^pupp* ]]; then
        download_path=$output_puppet/$tarball_name
        download_directory=$output_puppet
    else
        download_path=$output_tarball/$tarball_name
        download_directory=$output_tarball
    fi

    if [ -e $download_path ]; then
        echo "Already have $download_path"
        continue
    fi

    # We have 6 packages from the text file starting with the character "!":
    # they require special handling besides the common process: remove directory,
    # remove text from some files, clone a git repository, etc.

    if [[ "$line" =~ ^'!' ]]; then
        echo $tarball_name
        pushd $output_tarball > /dev/null
        if [ "$tarball_name" = "mariadb-10.1.28.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            mkdir $directory_name
            tar xf $tarball_name --strip-components 1 -C $directory_name
            rm $tarball_name
            pushd $directory_name > /dev/null
            rm -rf storage/tokudb
            rm ./man/tokuft_logdump.1 ./man/tokuftdump.1
            sed -e s/tokuft_logdump.1//g -i man/CMakeLists.txt
            sed -e s/tokuftdump.1//g -i man/CMakeLists.txt
            popd > /dev/null
            tar czvf $tarball_name $directory_name
            rm -rf $directory_name
            popd > /dev/null   # pushd $directory_name
        elif [[ "$tarball_name" = 'chartmuseum-v0.12.0-amd64' ]]; then
            download_file --quiet "$tarball_url" "$tarball_name"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi
        elif [[ "$tarball_name" = "helm-2to3-0.10.0.tar.gz" ]]; then
            download_file --quiet "$tarball_url" "$tarball_name"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi
        elif [[ "$tarball_name" = 'OPAE_1.3.7-5_el7.zip' ]]; then
            srpm_path="${directory_name}/source_code/"
            download_file --quiet "$tarball_url" "$tarball_name"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            unzip "$tarball_name"
            cp "${srpm_path}/opae-intel-fpga-driver-2.0.1-10.src.rpm" .
            # Don't delete the original OPAE_1.3.7-5_el7.zip tarball.
            # We don't use it, but it will prevent re-downloading this file.
            #   rm -f "$tarball_name"

            rm -rf "$directory_name"
        elif [[ "${tarball_name}" = 'ice_comms-1.3.35.0.zip' ]]; then
            download_file --quiet "${tarball_url}" "${tarball_name}"
            if [ $? -ne 0 ]; then
                echo "Warning: failed to download '${tarball_url}'"
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

        elif [[ "$tarball_name" = 'MLNX_OFED_SRC-5.5-1.0.3.2.tgz' ]]; then
            srpm_path="${directory_name}/SRPMS/"
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null   # pushd $output_tarball
                continue
            fi

            tar -xf "$tarball_name"
            cp "${srpm_path}/mlnx-ofa_kernel-5.5-OFED.5.5.1.0.3.1.src.rpm" .
            cp "${srpm_path}/rdma-core-55mlnx37-1.55103.src.rpm" .
            cp "${srpm_path}/mlnx-tools-5.2.0-0.55103.src.rpm" .
            cp "${srpm_path}/mstflint-4.16.0-1.55103.src.rpm" .
            # Don't delete the original MLNX_OFED_LINUX tarball.
            # We don't use it, but it will prevent re-downloading this file.
            #   rm -f "$tarball_name"

            rm -rf "$directory_name"
        elif [ "$tarball_name" = "qat1.7.l.4.5.0-00034.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null  # pushd $output_tarball
                continue
            fi
        elif [ "$tarball_name" = "QAT1.7.L.4.14.0-00031.tar.gz" ]; then
            download_package "$tarball_name" "$tarball_url"
            if [ $? -ne 0 ]; then
                error_count=$((error_count + 1))
                popd > /dev/null  # pushd $output_tarball
                continue
            fi
        elif [ "$tarball_name" = "dpdk-kmods-2a9f0f72a2d926382634cf8f1de10e1acf57542b.tar.gz" ]; then
            dest_dir=dpdk-kmods
            git clone $tarball_url $dest_dir

            if [ ! -d $dest_dir ]; then
                echo "Error: Failed to git clone from '$tarball_url'"
                echo "$tarball_url" > "$output_log"
                error_count=$((error_count + 1))
                popd > /dev/null # pushd $output_tarball
                continue
            fi

            pushd $dest_dir > /dev/null
            rev=$util
            git checkout -b temp $rev
            rm -rf .git
            popd > /dev/null
            mv dpdk-kmods $directory_name
            tar czvf $tarball_name $directory_name
            rm -rf $directory_name
        elif [ "$tarball_name" = "tss2-930.tar.gz" ]; then
            dest_dir=ibmtpm20tss-tss
            for dl_src in $dl_source; do
                case $dl_src in
                    $dl_from_stx_mirror)
                        url="$(url_to_stx_mirror_url "$tarball_url" "$distro")"
                        ;;
                    $dl_from_upstream)
                        url="$tarball_url"
                        ;;
                    *)
                        echo "Error: Unknown dl_source '$dl_src'"
                        continue
                        ;;
                esac

                git clone $url $dest_dir
                if [ $? -eq 0 ]; then
                    # Success
                    break
                else
                    echo "Warning: Failed to git clone from '$url'"
                    continue
                fi
            done

            if [ ! -d $dest_dir ]; then
                echo "Error: Failed to git clone from '$tarball_url'"
                echo "$tarball_url" > "$output_log"
                error_count=$((error_count + 1))
                popd > /dev/null # pushd $output_tarball
                continue
            fi

            pushd $dest_dir > /dev/null
            branch=$util
            git checkout $branch
            rm -rf .git
            popd > /dev/null
            mv ibmtpm20tss-tss $directory_name
            tar czvf $tarball_name $directory_name
            rm -rf $directory_name
            popd > /dev/null  # pushd $dest_dir
        elif [[ "$tarball_name" =~ ^kernel-rt-.*[.]el.*[.]rpm ]]; then
            local el_release=""
            el_release=$(echo $tarball_name | rev | cut -d '.' -f 3 | rev)
            local extra_clone_args=""
            if [[ "$el_release" =~ ^el([0-9]*)[0-9_]*$ ]]; then
                extra_clone_args="-b c${BASH_REMATCH[1]} --single-branch"
            else
                echo "error: $tarball_name is not a valid EPEL kernel"
                error_count=$((error_count + 1))
                continue
            fi

            if ! (git clone $extra_clone_args $tarball_url || \
                    git clone $tarball_url ); then
                echo "error: failed to clone from $tarball_url"
                error_count=$((error_count + 1))
                continue
            fi

            pushd kernel-rt
            (
                rev=$util
                if ! git checkout $rev; then
                    echo "failed to checkout $rev from $tarball_url"
                    exit 1
                fi

                # get the CentOS tools for building SRPMs
                if ! git clone https://git.centos.org/centos-git-common; then
                    echo "error: failed to clone https://git.centos.org/centos-git-common"
                    exit 1
                fi

                # Create the SRPM using CentOS tools
                # bracketed to contain the PATH change
                if ! (PATH=$PATH:./centos-git-common into_srpm.sh -d .$el_release); then
                    echo "error: into_srpm.sh failed to build $tarball_name"
                    exit 1
                fi

                mv SRPMS/*.rpm ../${tarball_name}
            ) || error_count=$((error_count + 1))

            popd > /dev/null # pushd kernel-rt
            # Cleanup
            rm -rf kernel-rt
        elif [[ "$tarball_name" =~ ^rt-setup-*.*.rpm ]]; then
            git clone -b c8 --single-branch $tarball_url
            pushd rt-setup
            rev=$util
            git checkout -b spec $rev

            # get the CentOS tools for building SRPMs
            git clone https://git.centos.org/centos-git-common

            # Create the SRPM using CentOS tools
            # bracketed to contain the PATH change
            (PATH=$PATH:./centos-git-common into_srpm.sh -d .el8)
            mv SRPMS/*.rpm ..

            popd > /dev/null # pushd rt-setup
            # Cleanup
            rm -rf rt-setup
        elif [[ "$tarball_name" = "kdump-anaconda-addon-003-29-g4c517c5.tar.gz" ]]; then
            mkdir -p "$directory_name"
            pushd "$directory_name"

            src_rpm_name="$(echo "$tarball_url" | rev | cut -d/ -f1 | rev)"

            download_file --quiet "$tarball_url" "$src_rpm_name"
            if [ $? -eq 0 ]; then
                rpm2cpio "$src_rpm_name" | cpio --quiet -i "$tarball_name"
                mv "$tarball_name" ..
            else
                echo "Error: Failed to download '$tarball_url'"
                echo "$tarball_url" > "$output_log"
                error_count=$((error_count + 1))
            fi

            popd >/dev/null # pushd "$directory_name"
            rm -rf "$directory_name"
        elif [ "${tarball_name}" = "bcm_220.0.83.0.tar.gz" ]; then

            # "${util}" is the expected sha256sum of the downloaded tar archive.
            #
            # Check if the file is already downloaded and if its sha256sum is
            # correct.
            if [ -f "${tarball_name}" ] && \
                    ! check_sha256sum "${tarball_name}" "${util}"; then
                # Incorrect checksum. Maybe the previous download attempt
                # failed? Remove the file and attempt to re-download.
                rm -f "${tarball_name}"
            fi

            if ! [ -f "${tarball_name}" ]; then
                download_file --quiet "${tarball_url}" "${tarball_name}"
                if [ $? -ne 0 ]; then
                    echo "Warning: failed to download '${tarball_url}'"
                    error_count=$((error_count + 1))
                    popd > /dev/null   # pushd $output_tarball
                    continue
                fi

                if ! check_sha256sum "${tarball_name}" "${util}"; then
                    echo "Warning: incorrect sha256sum for '${tarball_url}'"
                    error_count=$((error_count + 1))
                    popd > /dev/null   # pushd $output_tarball
                    continue
                fi
            fi

            rm -rf "${directory_name}"

            if ! tar -xf "${tarball_name}" || \
                    ! cp "${directory_name}/Linux/Linux_Driver/netxtreme-bnxt_en-1.10.2-220.0.13.0.tar.gz" . || \
                    ! cp "${directory_name}/Linux/KMP-RoCE-Lib/KMP/Redhat/rhel7.9/libbnxt_re-220.0.5.0-rhel7u9.src.rpm" . ; then
                # Extraction failed. Remove the tar archive to allow another
                # attempt.
                rm -f "${tarball_name}"
                echo "Warning: Could not extract '${tarball_name}' or could not find expected files."
                error_count=$((error_count + 1))
            fi

            rm -rf "${directory_name}"

            # We do not delete the original tar archive we just extracted from,
            # so that it will not need to be downloaded again.
            #   rm -f "${tarball_name}"
        fi
        popd > /dev/null # pushd $output_tarball
        continue
    fi

    if [ -e $download_path ]; then
        echo "Already have $download_path"
        continue
    fi

    for dl_src in $dl_source; do
        case $dl_src in
            $dl_from_stx_mirror)
                url="$(url_to_stx_mirror_url "$tarball_url" "$distro")"
                ;;
            $dl_from_upstream)
                url="$tarball_url"
                ;;
            *)
                echo "Error: Unknown dl_source '$dl_src'"
                continue
                ;;
        esac

        download_file --quiet "$url" "$download_path"
        if [[ $? -eq 0 ]] ; then
            if ! is_tarball "$download_path"; then
                echo "Warning: file from $url is not a tarball."
                \rm "$download_path"
                continue
            fi
            echo "Ok: $download_path"
            pushd $download_directory > /dev/null
            directory_name_original=$(tar -tf $tarball_name | head -1 | cut -f1 -d"/")
            if [ "$directory_name" != "$directory_name_original" ]; then
                mkdir -p $directory_name
                tar xf $tarball_name --strip-components 1 -C $directory_name
                tar -czf $tarball_name $directory_name
                rm -r $directory_name
            fi
            popd > /dev/null
            break
        else
            echo "Warning: Failed to download $url" 1>&2
            continue
        fi
    done

    if [ ! -e $download_path ]; then
        echo "Error: Failed to download $tarball_url" 1>&2
        echo "$tarball_url" > "$output_log"
        error_count=$((error_count + 1))
    fi
done

# End of file

if [ $error_count -ne 0 ]; then
    echo ""
    echo "Encountered $error_count errors"
    exit 1
fi

exit 0

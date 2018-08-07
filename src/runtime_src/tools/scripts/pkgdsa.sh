#!/bin/bash

# This script creates rpm and deb packages for dsabin and mcs files that
# installed to /lib/firmware/xilinx
#
# The script is assumed to run on a host or docker that has all the
# necessary rpm/deb tools installed.
#
# Examples:
#
#  Package DSA from platform dir in default sdx install
#  % pkgdsa.sh \
#       -dsa xilinx_vcu1525_dynamic_5_1 \
#       -xrt 2.1.0 \
#       -cl 12345678
#
#  Package DSA from platform dir in specified sdx install
#  % pkgdsa.sh \
#       -dsa xilinx_vcu1525_dynamic_5_1 \
#       -sdx <workspace>/2018.2/prep/rdi/sdx \
#       -xrt 2.1.0 \
#       -cl 12345678
#
#  Package DSA from specified DSA platform dir 
#  % pkgdsa.sh -dsa xilinx_vcu1525_dynamic_5_1 \
#       -dsadir <workspace>2018.2/prep/rdi/sdx/platforms/xilinx_vcu1525_dynamic_5_1 \
#       -xrt 2.1.0 \
#       -cl 12345678

opt_dsa=""
opt_dsadir=""
opt_pkgdir="/tmp/pkgdsa"
opt_sdx="/proj/xbuilds/2018.2_daily_latest/installs/lin64/SDx/2018.2"
opt_xrt=""
opt_cl=0
opt_dev=0

dsa_version="5.1"

usage()
{
    echo "package-dsa"
    echo
    echo "-dsa <name>                Name of dsa, e.g. xilinx-vcu1525-dynamic_5_1"
    echo "-sdx <path>                Full path to SDx install (default: 2018.2_daily_latest)"
    echo "-xrt <version>             Requires xrt >= <version>"
    echo "-cl <changelist>           Changelist for package revision"
    echo "[-dsadir <path>]           Full path to directory with platform (default: <sdx>/platform/<dsa>)"
    echo "[-pkgdir <path>]           Full path to direcory used by rpm,dep,xbins (default: /tmp/pkgdsa)"
    echo "[-dev]                     Build development package"
    echo "[-help]                    List this help"

    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -help)
            usage
            ;;
        -cl)
            shift
            opt_cl=$1
            shift
            ;;
        -dev)
            opt_dev=1
            shift
            ;;
        -dsa)
            shift
            opt_dsa=$1
            shift
            ;;
        -dsadir)
            shift
            opt_dsadir=$1
            shift
            ;;
        -pkgdir)
            shift
            opt_pkgdir=$1
            shift
            ;;
        -xrt)
            shift
            opt_xrt=$1
            shift
            ;;
        -sdx)
            shift
            opt_sdx=$1
            shift
            ;;
        *)
            echo "$1 invalid argument."
            usage
            ;;
    esac
done

if [ "X$opt_sdx" == "X" ]; then
   echo "Must specify -sdx"
   usage
   exit 1
fi

if [ "X$opt_dsa" == "X" ]; then
   echo "Must specify -dsa"
   usage
   exit 1
fi

if [ "X$opt_dsadir" == "X" ]; then
   opt_dsadir=$opt_sdx/platforms/$opt_dsa
fi

if [ ! -d $opt_dsadir ]; then
  echo "Specified dsa "$dsa" does not exist in '$opt_dsadir'"
  usage
  exit 1
fi

if [ "X$opt_xrt" == "X" ]; then
  echo "Must specify -xrt"
  usage
  exit 1;
fi

if [ "X${XILINX_XRT}" == "X" ]; then
  echo "Environment variable XILINX_XRT is not set.  Please the XRT setup script."
#  exit 1;
fi

# get dsa, version, and revision
dsa=$(echo ${opt_dsa:0:${#opt_dsa}-4} | tr '_' '-')
version=$(echo ${opt_dsa:(-3)} | tr '_' '.')
revision=$opt_cl

echo "================================================================"
echo "DSA       : $dsa"
echo "DSADIR    : $opt_dsadir"
echo "PKGDIR    : $opt_pkgdir"
echo "XRT       : $opt_xrt"
echo "VERSION   : $version"
echo "REVISION  : $revision"
echo "XILINX_XRT: $XILINX_XRT"
echo "================================================================"

# DSABIN variables
dsaFile=""
mcsPrimary=""
mcsSecondary=""
fullBitFile=""
clearBitstreamFile=""
dsaXmlFile="dsa.xml"
featureRomTimestamp=""
fwScheduler=""
fwManagement=""
vbnv=""
pci_vendor_id="0x0000"
pci_device_id="0x0000"
pci_subsystem_id="0x0000"
dsabinOutputFile=""

createEntityAttributeArray ()
{
  unset ENTITY_ATTRIBUTES_ARRAY
  declare -A -g ENTITY_ATTRIBUTES_ARRAY

  for kvp in $ENTITY_ATTRIBUTES; do
    set -- `echo $kvp | tr '=' ' '`
    # Remove leading and trailing quotes
    value=$2
    value="${value%\"}"
    value="${value#\"}"
    ENTITY_ATTRIBUTES_ARRAY[$1]=$value
  done
}

readSAX () {
  # Set Input Field Spearator to be local to this function and change it to
  # the '>' character
  local IFS=\>

  # Read the input from stdin and stop when the '<' character is seen.
  read -d \< ENTITY_LINE

  local ret=$?

  # Remove any trailing "/>" characters
  ENTITY_LINE="${ENTITY_LINE///>/}"

  # Remove any carriage returns
  ENTITY_LINE="${ENTITY_LINE//$'\n'/}"

  # Remove any training whitespaces
  ENTITY_LINE="${ENTITY_LINE%"${ENTITY_LINE##*[![:space:]]}"}" 

  ENTITY_NAME="${ENTITY_LINE%% *}"
  ENTITY_ATTRIBUTES="${ENTITY_LINE#* }"

  return $ret
}

recordDsaFiles()
{
   # Full Static Bitstream
   if [ "${ENTITY_ATTRIBUTES_ARRAY[Type]}" == "FULL_BIT" ]; then
     fullBitFile="${ENTITY_ATTRIBUTES_ARRAY[Name]}"
   fi

   # MCS Primary
   if [ "${ENTITY_ATTRIBUTES_ARRAY[Type]}" == "MCS" ]; then
     mcsPrimary="firmware/${ENTITY_ATTRIBUTES_ARRAY[Name]}"
   fi

   # MCS Secondary
   if [ "${ENTITY_ATTRIBUTES_ARRAY[Type]}" == "SECONDARY_MCS" ]; then
     mcsSecondary="firmware/${ENTITY_ATTRIBUTES_ARRAY[Name]}"
   fi

   # Clear Bitstream
   if [ "${ENTITY_ATTRIBUTES_ARRAY[Type]}" == "CLEAR_BIT" ]; then
     clearBitstreamFile="${ENTITY_ATTRIBUTES_ARRAY[Name]}"
   fi
}

readDsaMetaData()
{
  # -- Extract the dsa.xml metadata file --
  unzip -q -d . "${dsaFile}" "${dsaXmlFile}"

  while readSAX; do
    # Record the data types
    if [ "${ENTITY_NAME}" == "File" ]; then
      createEntityAttributeArray
      recordDsaFiles
    fi    

    # Record the FeatureRomTimestamp
    if [ "${ENTITY_NAME}" == "DSA" ]; then
      createEntityAttributeArray

      featureRomTimestamp="${ENTITY_ATTRIBUTES_ARRAY[FeatureRomTimestamp]}"

      vendor="${ENTITY_ATTRIBUTES_ARRAY[Vendor]}"
      board="${ENTITY_ATTRIBUTES_ARRAY[BoardId]}"
      name="${ENTITY_ATTRIBUTES_ARRAY[Name]}"
      versionMajor="${ENTITY_ATTRIBUTES_ARRAY[VersionMajor]}"
      versionMinor="${ENTITY_ATTRIBUTES_ARRAY[VersionMinor]}"
      vbnv=$(printf "%s:%s:%s:%s.%s" "${vendor}" "${board}" "${name}" "${versionMajor}" "${versionMinor}")
    fi    

    # Record the PCIeID information 
    if [ "${ENTITY_NAME}" == "PCIeId" ]; then
      createEntityAttributeArray

      pci_vendor_id="${ENTITY_ATTRIBUTES_ARRAY[Vendor]}"
      pci_device_id="${ENTITY_ATTRIBUTES_ARRAY[Device]}"
      pci_subsystem_id="${ENTITY_ATTRIBUTES_ARRAY[Subsystem]}"
    fi    
  done < "${dsaXmlFile}"
}

initDsaBinEnvAndVars()
{
    # Clean out the dsabin directory
    /bin/rm -rf "${opt_pkgdir}/dsabin"
    mkdir -p "${opt_pkgdir}/dsabin"
    cd "${opt_pkgdir}/dsabin"

    # -- Get the DSA for this platform --
    dsaFile="${opt_dsadir}/hw/${opt_dsa}.dsa"
    if [ ! -f "${dsaFile}" ]; then
       echo "Error: DSA file does not exist: ${dsaFile}"
       popd >/dev/null
       exit 1
    fi
  
    # Read the metadata from the dsa.xml file 
    readDsaMetaData
  
    # -- Extract the MCS Files --
    if [ "${mcsPrimary}" != "" ]; then
       echo "Info: Extracting MCS Primary file: ${mcsPrimary}"
       unzip -q -d . "${dsaFile}" "${mcsPrimary}"
    fi

    if [ "${mcsSecondary}" != "" ]; then
       echo "Info: Extracting MCS Secondary file: ${mcsSecondary}"
       unzip -q -d . "${dsaFile}" "${mcsSecondary}"
    fi

    # -- Extract the bitstreams --
    if [ "${fullBitFile}" != "" ]; then
       echo "Info: Extracting Full Bitstream file: ${fullBitFile}"
       unzip -q -d "./firmware" "${dsaFile}" "${fullBitFile}"
    fi

    if [ "${clearBitstreamFile}" != "" ]; then
       echo "Info: Extracting Clear Bitstream file: ${clearBitstreamFile}"
       unzip -q -d "./firmware" "${dsaFile}" "${clearBitstreamFile}"
    fi

    # -- Determine firmware --
    if [[ ${opt_dsa} =~ "xdma" ]]; then
      fwScheduler="${XILINX_XRT}/share/fw/sched.bin"
      fwManagement="${XILINX_XRT}/share/fw/xmc.bin"
    else
      fwScheduler="${XILINX_XRT}/share/fw/sched.bin"
      fwManagement="${XILINX_XRT}/share/fw/mgmt.bin"
    fi
}

dodsabin()
{
    pushd $opt_pkgdir > /dev/null
    echo "Creating dsabin for: ${opt_dsa}"

    initDsaBinEnvAndVars

    # Build the xclbincat options
    xclbinOpts=""

    # -- MCS_PRIMARY image --
    if [ "$mcsPrimary" != "" ]; then
       xclbinOpts+=" -s MCS_PRIMARY ${mcsPrimary}"
    fi
    
    # -- MCS_SECONDARY image --
    if [ "$mcsSecondary" != "" ]; then
       xclbinOpts+=" -s MCS_SECONDARY ${mcsSecondary}"
    fi
    
    # -- Firmware: Scheduler --
    if [ "${fwScheduler}" != "" ]; then
       if [ -f "${fwScheduler}" ]; then
         xclbinOpts+=" -s SCHEDULER ${fwScheduler}"
       else
         echo "Warning: Scheduler firmware does not exist: ${fwScheduler}"
       fi
    fi
    
    # -- Firmware: Management --
    if [ "${fwManagement}" != "" ]; then
       if [ -f "${fwManagement}" ]; then
         xclbinOpts+=" -s FIRMWARE ${fwManagement}"
       else
         echo "Warning: Management firmware does not exist: ${fwManagement}"
      fi
    fi

    # -- Clear bitstream --
    if [ "${clearBitstreamFile}" != "" ]; then
       xclbinOpts+=" -s CLEAR_BITSTREAM ./firmware/${clearBitstreamFile}"
    fi

    # -- FeatureRom Timestamp --
    if [ "${featureRomTimestamp}" != "" ]; then
       xclbinOpts+=" --kvp featureRomTimestamp:${featureRomTimestamp}"
    else
       echo "Warning: Missing featureRomTimestamp"
    fi

    # -- VBNV --
    if [ "${vbnv}" != "" ]; then
       xclbinOpts+=" --kvp platformVBNV:${vbnv}"
    else
       echo "Warning: Missing Platform VBNV value"
    fi

    # -- Mode Hardware PR --
    xclbinOpts+=" --kvp mode:hw_pr"

    # -- Output filename --
    localFeatureRomTimestamp="${featureRomTimestamp}"
    if [ "${localFeatureRomTimestamp}" == "" ]; then
      localFeatureRomTimestamp="0"
    fi

    dsabinOutputFile=$(printf "%s-%s-%s-%016d.dsabin" "${pci_vendor_id#0x}" "${pci_device_id#0x}" "${pci_subsystem_id#0x}" "${localFeatureRomTimestamp}")
    xclbinOpts+=" -o ./firmware/${dsabinOutputFile}"    


    echo "${XILINX_XRT}/bin/xclbincat ${xclbinOpts}"
    ${XILINX_XRT}/bin/xclbincat ${xclbinOpts}

    popd >/dev/null
}

dodebdev()
{
    dir=debbuild/$dsa-$version-dev
    mkdir -p $opt_pkgdir/$dir/DEBIAN
cat <<EOF > $opt_pkgdir/$dir/DEBIAN/control

package: $dsa-dev
architecture: amd64
version: $version-$revision
priority: optional
depends: $dsa (>= $version)
description: Xilinx development DSA
maintainer: soren.soe@xilinx.com

EOF

    mkdir -p $opt_pkgdir/$dir/opt/xilinx/platform/$opt_dsa/hw
    mkdir -p $opt_pkgdir/$dir/opt/xilinx/platform/$opt_dsa/sw
    rsync -avz $opt_dsadir/$opt_dsa.xpfm $opt_pkgdir/$dir/opt/xilinx/platform/$opt_dsa/
    rsync -avz $opt_dsadir/hw/$opt_dsa.dsa $opt_pkgdir/$dir/opt/xilinx/platform/$opt_dsa/hw/
    rsync -avz $opt_dsadir/sw/$opt_dsa.spfm $opt_pkgdir/$dir/opt/xilinx/platform/$opt_dsa/sw/
    dpkg-deb --build $opt_pkgdir/$dir

    echo "================================================================"
    echo "* Please locate dep for $dsa in: $opt_pkgdir/$dir"
    echo "================================================================"
}

dodeb()
{
    dir=debbuild/$dsa-$version
    mkdir -p $opt_pkgdir/$dir/DEBIAN
cat <<EOF > $opt_pkgdir/$dir/DEBIAN/control

package: $dsa
architecture: amd64
version: $version-$revision
priority: optional
depends: xrt (>= $opt_xrt)
description: Xilinx deployment DSA
 This DSA depends on xrt >= $opt_xrt.
maintainer: soren.soe@xilinx.com

EOF

    mkdir -p $opt_pkgdir/$dir/lib/firmware/xilinx
    rsync -avz $opt_pkgdir/dsabin/firmware/ $opt_pkgdir/$dir/lib/firmware/xilinx
    mkdir -p $opt_pkgdir/$dir/opt/xilinx/dsa/$opt_dsa/test
    rsync -avz ${opt_dsadir}/test/ $opt_pkgdir/$dir/opt/xilinx/dsa/$opt_dsa/test
    dpkg-deb --build $opt_pkgdir/$dir

    echo "================================================================"
    echo "* Please locate dep for $dsa in: $opt_pkgdir/$dir"
    echo "================================================================"
}

dorpmdev()
{
    dir=rpmbuild
    mkdir -p $opt_pkgdir/$dir/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat <<EOF > $opt_pkgdir/$dir/SPECS/$opt_dsa-dev.spec

buildroot:  %{_topdir}
summary: Xilinx development DSA
name: $dsa-dev
version: $version
release: $revision
license: apache
vendor: Xilinx Inc

requires: $dsa >= $version

%description
Xilinx development DSA.

%prep

%install
mkdir -p %{buildroot}/opt/xilinx/platform/$opt_dsa/hw
mkdir -p %{buildroot}/opt/xilinx/platform/$opt_dsa/sw
rsync -avz $opt_dsadir/$opt_dsa.xpfm %{buildroot}/opt/xilinx/platform/$opt_dsa/
rsync -avz $opt_dsadir/hw/$opt_dsa.dsa %{buildroot}/opt/xilinx/platform/$opt_dsa/hw/
rsync -avz $opt_dsadir/sw/$opt_dsa.spfm %{buildroot}/opt/xilinx/platform/$opt_dsa/sw/

%files
%defattr(-,root,root,-)
/opt/xilinx

%changelog
* Fri May 18 2018 Soren Soe <soren.soe@xilinx.com> - 5.1-1
  Created by script

EOF

    echo "rpmbuild --define '_topdir $opt_pkgdir/$dir' -ba $opt_pkgdir/$dir/SPECS/$opt_dsa-dev.spec"
    $dir --define '_topdir '"$opt_pkgdir/$dir" -ba $opt_pkgdir/$dir/SPECS/$opt_dsa-dev.spec

    echo "================================================================"
    echo "* Please locate rpm for dsa in: $opt_pkgdir/$dir/RPMS/x86_64"
    echo "================================================================"
}

dorpm()
{
    dir=rpmbuild
    mkdir -p $opt_pkgdir/$dir/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat <<EOF > $opt_pkgdir/$dir/SPECS/$opt_dsa.spec

buildroot:  %{_topdir}
summary: Xilinx deployment DSA
name: $dsa
version: $version
release: $revision
license: apache
vendor: Xilinx Inc
autoreqprov: no
requires: xrt >= $opt_xrt

%description
Xilinx deployment DSA.  This DSA depends on xrt >= $opt_xrt.

%prep

%install
mkdir -p %{buildroot}/lib/firmware/xilinx
cp $opt_pkgdir/dsabin/firmware/* %{buildroot}/lib/firmware/xilinx
mkdir -p %{buildroot}/opt/xilinx/dsa/$opt_dsa/test
cp ${opt_dsadir}/test/* %{buildroot}/opt/xilinx/dsa/$opt_dsa/test

%files
%defattr(-,root,root,-)
/lib/firmware/xilinx
/opt/xilinx/dsa/$opt_dsa/test

%changelog
* Fri May 18 2018 Soren Soe <soren.soe@xilinx.com> - 5.1-1
  Created by script

EOF

    echo "rpmbuild --define '_topdir $opt_pkgdir/$dir' -ba $opt_pkgdir/$dir/SPECS/$opt_dsa.spec"
    rpmbuild --define '_topdir '"$opt_pkgdir/$dir" -ba $opt_pkgdir/$dir/SPECS/$opt_dsa.spec

    echo "================================================================"
    echo "* Please locate rpm for dsa in: $opt_pkgdir/$dir/RPMS/x86_64"
    echo "================================================================"
}

FLAVOR=`grep '^ID=' /etc/os-release | awk -F= '{print $2}'`
FLAVOR=`echo $FLAVOR | tr -d '"'`

if [ $FLAVOR == "centos" ]; then
 if [ $opt_dev == 1 ]; then
     dorpmdev
 else
     dodsabin
     dorpm
 fi
fi

if [ $FLAVOR == "ubuntu" ]; then
 if [ $opt_dev == 1 ]; then
     dodebdev
 else
     dodsabin
     dodeb
 fi
fi

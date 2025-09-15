rm -f seed.iso
mkdir -p seed
cp user-data.yaml seed/user-data
cp meta-data.yaml seed/meta-data
hdiutil makehybrid -o seed.iso seed -iso -joliet -default-volume-name cidata
rm -rf seed

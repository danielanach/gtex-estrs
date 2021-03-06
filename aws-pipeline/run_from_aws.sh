#!/bin/bash

SUPERBATCHPATH=$1

OUTBUCKET=s3://gtex-hipstr/vcfs
HOMEDIR=/root/

superbatch=$(basename $SUPERBATCHPATH)

usage()
{
    BASE=$(basename -- "$0")
    echo "Run HipSTR on GTEx
Usage:
    $BASE <superbatch>

Does the following:
1. Set up
2. Download necessary files
3. Create jobs
4. Run those jobs
5. Upload results to S3 bucket
6. Terminate
"
    terminate
    exit 1
}

terminate() {
    INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
    # Get log
    sudo aws s3 cp --output table /var/log/cloud-init-output.log ${OUTBUCKET}/log/${superbatch}.log
    # Terminate instance
    echo "Terminating instance ${INSTANCE_ID}"
    sudo aws ec2 terminate-instances --output table --instance-ids ${INSTANCE_ID} # TODO put back
    exit 1 # shouldn't happen
}

test -z ${SUPERBATCHPATH} && usage

die()
{
    BASE=$(basename -- "$0")
    echo "$BASE: error: $@" >&2
    terminate
    exit 1
}

# Set of directories for inputs/outsputs on mounted EBS drive
sudo mkfs -t ext4 /dev/xvdf
sudo mkdir -p /storage
sudo mount /dev/xvdf /storage/
sudo chmod 777 /storage/

# Set configuration to try to avoid s3 timeout
aws configure set default.s3.max_concurrent_requests 1

# Download files
sudo mkdir -p /storage/tmp || die "Could not make tmp directory"
aws s3 cp ${SUPERBATCHPATH} /storage/tmp/superbatch.txt || die "Could not get superbatch"

# Make directory for inputs/outputs
sudo mkdir -p /storage/vcfs || die "Could not make vcfs directory"

# Update github
cd ${HOMEDIR}/source/gtex-estrs
git pull

# Download reference genome and HipSTR reference
sudo mkdir -p /storage/resources/
cd /storage/resources/
wget https://github.com/HipSTR-Tool/HipSTR-references/raw/master/human/GRCh37.hipstr_reference.bed.gz
gunzip GRCh37.hipstr_reference.bed.gz
aws s3 cp s3://ssc-psmc/Homo_sapiens_assembly19.fasta . || die "could not get ref genome"
samtools faidx Homo_sapiens_assembly19.fasta || die "could not index fasta"

# Download all bam files to EBS storage
sudo mkdir -p /storage/gtex-data
sudo mkdir -p /storage/gtex-data/sra
sudo mkdir -p /storage/gtex-data/wgs
mkdir -p /home/ubuntu/dbgap/
sudo cp /root/dbgap/prj_12604.ngc /home/ubuntu/dbgap/
vdb-config --import /home/ubuntu/dbgap/prj_12604.ngc /storage/gtex-data/

for sample in $(cat /storage/tmp/superbatch.txt)
do
    cd /storage/gtex-data/ # go to dbgap directory
    echo "checking $sample"
    # Check if already done
    x=$(aws s3 ls ${OUTBUCKET}/${sample}_hipstr.vcf.gz.tbi | awk '{print $NF}')
    test -z $x || continue
    echo "processing $sample"
    # Download files using aspera
    prefetch --max-size 200G ${sample}
    sam-dump --primary sra/${sample}.sra | samtools view -bS > wgs/${sample}.bam
#    sam-dump -u --aligned-region 11:2191318-2193345 ${sample} | samtools view -bS > wgs/${sample}.bam # TODO remove line
    samtools index wgs/${sample}.bam
    # Run HipSTR
    cd ${HOMEDIR}/source/gtex-estrs/aws-pipeline
    ./run_hipstr_gtex_aws.sh ${sample}
    aws s3 cp /storage/vcfs/${sample}.vcf.gz ${OUTBUCKET}/${sample}_hipstr.vcf.gz
    aws s3 cp /storage/vcfs/${sample}.vcf.gz.tbi ${OUTBUCKET}/${sample}_hipstr.vcf.gz.tbi
    # Remove files
    rm -rf /storage/gtex-data/sra/${sample}*
    rm -rf /storage/gtex-data/wgs/${sample}*
    rm -rf /storage/vcfs/${sample}*
done

terminate


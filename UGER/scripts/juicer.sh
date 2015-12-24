#!/bin/bash
##########
#The MIT License (MIT)
#
# Copyright (c) 2015 Aiden Lab
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.
##########
# Alignment script. Sets the reference genome and genome ID based on the input
# arguments (default human, DpnII). Optional arguments are the queue for the 
# alignment (default short), key for menu entry, description for stats file, 
# using the short read aligner, read end (to align one read end using short 
# read aligner), early exit (to exit before the final creation of .hic files),
# merge (to start jobs at merge step), and the top-level directory (default 
# current directory). In lieu of setting the genome ID, you can instead set the
# reference sequence and the chrom.sizes file path, but the directory 
# containing the reference sequence must also contain the BWA index files.
#
# Splits the fastq files, creates jobs to align them, creates merge jobs that
# wait for the alignment to finish, and creates a final merge job.
#
# Also creates "cleanup" jobs that at each stage, deletes jobs off the cluster
# if any one of them fails.
#
# If all is successful, takes the final merged file, removes name duplicates,
# removes PCR duplicates, and creates the hic job and stats job.  Final
# product will be hic file and stats file in the aligned directory.
#                                                                       
# [topDir]/fastq  - Should contain the fastq files. This code assumes that
#                   there is an "R" in the appropriate files, i.e. *R*.fastq
# From the top-level directory, the following two directories are created:
#                                                                              
# [topDir]/splits  - Where to write the scratch split files (fastq files and
#                    intermediate SAM files). This can be deleted after 
#                    execution.
# [topDir]/aligned - Where to write the final output files.
#
# The following globals should be set correctly before proceeding:
#
# splitsize - The number of lines that each split fastq should contain. Larger
#             means fewer files and longer overall, but too small means there
#             are so many jobs that the cluster won't run them
# read1str  - portion of fastq filename that indicates this is the "read 1"
#             file; used to loop over only the read 1 and within that loop,
#             also align read 2 and merge.  If this is not set correctly,
#             script will not work. The error will often manifest itself
#             through a "*" in the name because the wildcard was not able to
#             match any files with the read1str.   
shopt -s extglob

## Set the following variables to work with your system

# set global tmpdir so no problems with /var/tmp
#export TMPDIR=/broad/hptmp

## use cluster load commands:
usePath=/broad/software/scripts/useuse
load_bwa="use .bwa-0.7.12"
load_java="use Java-1.7"
load_cluster="use UGER"
load_coreutils="use Coreutils"
# Juicer directory, contains scripts/, references/, and restriction_sites/
juiceDir="/broad/aidenlab"
# default queue, can also be set in options
queue="short"
# default long queue, can also be set in options
long_queue="long"
# size to split fastqs. adjust to match your needs. 4000000=1M reads per split
splitsize=40000000
# fastq files should look like filename_R1.fastq and filename_R2.fastq 
# if your fastq files look different, change this value
read1str="_R1" 
read2str="_R2" 
# unique name for jobs in this run
groupname="a"`date +%s`

## Default options, overridden by command line arguments

# top level directory, can also be set in options
topDir=`pwd`
# restriction enzyme, can also be set in options
site="DpnII"
# genome ID, default to human, can also be set in options
genomeID="hg19"
# normally both read ends are aligned with long read aligner; 
# if one end is short, this is set                 
shortreadend=0
# description, default empty                                          
about=""

## Read arguments                                                     
usageHelp="Usage: ${0##*/} -g genomeID [-d topDir] [-q queue] [-l long queue] [-s site] [-a about] [-R end] [-S stage] [-p chrom.sizes path] [-y restriction site file path] [-z reference sequence path] [-r] [-h]"
genomeHelp="   genomeID must be defined in the script, e.g. \"hg19\" or \"mm10\" (default \"$genomeID\")\n   alternatively, it can be defined using the -z command"
dirHelp="   [topDir] is the top level directory (default \"$topDir\")\n     [topDir]/fastq must contain the fastq files\n     [topDir]/splits will be created to contain the temporary split files\n     [topDir]/aligned will be created for the final alignment"
queueHelp="   [queue] is the queue for running alignments (default \"$queue\")"
longQueueHelp="   [long queue] is the queue for running longer jobs such as the hic file creation (default \"$long_queue\")"
siteHelp="   [site] must be defined in the script, e.g.  \"HindIII\" or \"MboI\" (default \"$site\")"
shortHelp2="   [end]: use the short read aligner on read end, must be one of 1 or 2 "
stageHelp="   [stage]: must be one of \"merge\", \"dedup\", \"final\", or \"early\". Use \"merge\" when alignment has finished but the merged_sort file has not yet been created. Use \"dedup\" when the files have been merged into merged_sort but merged_nodups has not yet been created. Use \"final\" when the reads have been deduped into merged_nodups but the final stats and hic files have not yet been created. Use \"early\" for an early exit, before the final creation of the stats and hic files"
shortHelp="   -r: use the short read version of the aligner, bwa aln (default: long read, bwa mem)"
aboutHelp="   -a: enter description of experiment, enclosed in single quotes"
pathHelp="   -p: enter path for chrom.sizes file"
refSeqHelp="   -z: enter path for reference sequence file, BWA index file must be in same directory"
siteFileHelp="   -y: enter path for restriction site file (locations of restriction sites in genome)"
helpHelp="   -h: print this help and exit"

printHelpAndExit() {
    echo "$usageHelp"
    echo "$genomeHelp"
    echo -e "$dirHelp"
    echo "$queueHelp"
    echo "$longQueueHelp"
    echo "$siteHelp"
    echo "$shortHelp2"
    echo "$shortHelp"
    echo "$stageHelp"
    echo "$aboutHelp"
    echo "$pathHelp"
    echo "$siteFileHelp"
    echo "$refSeqHelp"
    echo "$helpHelp"
    exit $1
}

while getopts "d:g:R:k:a:hrmefq:s:p:l:y:z:S:" opt; do
    case $opt in
	g) genomeID=$OPTARG ;;
	h) printHelpAndExit 0;;
	d) topDir=$OPTARG ;;
	l) long_queue=$OPTARG ;;
	q) queue=$OPTARG ;;
	s) site=$OPTARG ;;
	R) shortreadend=$OPTARG ;;
	r) shortread=1 ;;  #use short read aligner
  a) about=$OPTARG ;;
  p) genomePath=$OPTARG ;;  
  y) site_file=$OPTARG ;;
	z) refSeq=$OPTARG ;;
  S) stage=$OPTARG ;;
	[?]) printHelpAndExit 1;;
    esac
done

if [ ! -z "$stage" ]
then
    case $stage in
        merge) merge=1 ;;
        dedup) dedup=1 ;;
        early) earlyexit=1 ;;
	      final) final=1 ;; 
	      *)  echo "$usageHelp"
            echo "$stageHelp"
            exit 1
    esac
fi

## Set reference sequence based on genome ID
if [ -z "$refSeq" ]
then 
    case $genomeID in
		mm9) refSeq="${juiceDir}/references/Mus_musculus_assembly9_norandom.fasta";;
		mm10) refSeq="${juiceDir}/references/Mus_musculus_assembly10.fasta";;
		hg38) refSeq="${juiceDir}/references/hg38.fa";;
		hg19) refSeq="${juiceDir}/references/Homo_sapiens_assembly19.fasta";;

	*)  echo "$usageHelp"
            echo "$genomeHelp"
            exit 1
    esac
else
    ## Reference sequence passed in, so genomePath must be set for the .hic file
    ## to be properly created
    if [ -z "$genomePath" ]
        then
        echo "***! You must define a chrom.sizes file via the \"-p\" flag that delineates the lengths of the chromosomes in the genome at $refSeq";
        exit 100;
    fi
fi

## Check that refSeq exists 
if [ ! -e "$refSeq" ]; then
    echo "***! Reference sequence $refSeq does not exist";
    exit 100;
fi
## Check that index for refSeq exists
if [ ! -e "${refSeq}.bwt" ]; then
    echo "***! Reference sequence $refSeq does not appear to have been indexed. Please run bwa index on this file before running juicer.";
    exit 100;
fi

## Set ligation junction based on restriction enzyme
case $site in
	HindIII) ligation="AAGCTAGCTT";;
	DpnII) ligation="GATCGATC";;
	MboI) ligation="GATCGATC";;
	NcoI) ligation="CCATGCATGG";;
	*)  ligation="XXXX"
      echo "$site not listed as recognized enzyme. Using $site_file as site file"
      echo "Ligation junction is undefined"
      exit 100
esac

## If short read end is set, make sure it is 1 or 2
case $shortreadend in
	0) ;;
	1) ;;
	2) ;;
	*) echo "$usageHelp"
		 echo "$shortHelp2"
		 exit 100
esac

if [ -z $site_file ]
then
    site_file="${juiceDir}/restriction_sites/${genomeID}_${site}.txt"
fi

## Check that site file exists, needed for fragment number for merged_nodups
if [ ! -e "$site_file" ]; then
    echo "***! $site_file does not exist. It must be created before running this script."
    exit 100
fi

## Directories to be created and regex strings for listing files
splitdir=${topDir}"/splits"
donesplitdir=$topDir"/done_splits"
fastqdir=${topDir}"/fastq/*_R*.fastq*"
outputdir=${topDir}"/aligned"
tmpdir=${topDir}"/HIC_tmp"

## Check that fastq directory exists and has proper fastq files
if [ ! -d "$topDir/fastq" ]; then
	echo "Directory \"$topDir/fastq\" does not exist."
	echo "Create \"$topDir/fastq\" and put fastq files to be aligned there."
	echo "Type \"juicer.sh -h\" for help"
	exit 100
else 
	if stat -t ${fastqdir} >/dev/null 2>&1
		then
		echo "(-: Looking for fastq files...fastq files exist"
	else
		if [ ! -d "$splitdir" ]; then 
			echo "***! Failed to find any files matching ${fastqdir}"
			echo "***! Type \"juicer.sh -h \" for help"
			exit 100		
		fi
	fi
fi

## Create output directory, only if not in dedup or final stages
if [[ -d "$outputdir" && -z "$final" && -z "$dedup" ]] 
then
    echo "***! Move or remove directory \"$outputdir\" before proceeding."
	  echo "***! Type \"juicer.sh -h \" for help"
	  exit 100			
else
    if [[ -z "$final" && -z "$dedup" ]]; then
        mkdir $outputdir || { echo '***! Unable to create ${outputdir}, check permissions.' ; exit 100; } 
    fi
fi

## Create split directory
if [ -d "$splitdir" ]; then
    splitdirexists=1
else
    mkdir $splitdir || { echo '***! Unable to create ${splitdir}, check permissions.' ; exit 100; }
fi

## Create temporary directory, used for sort later
if [ ! -d "$tmpdir" ] && [ -z "$final" ] && [ -z "$dedup" ]; then
    mkdir $tmpdir
    chmod 777 $tmpdir
fi

## Arguments have been checked and directories created. Now begins
## the real work of the pipeline

source $usePath
$load_cluster

## ARRAY holds the names of the jobs as they are submitted
countjobs=0
declare -a ARRAY

fastqsize=`ls -lL ${fastqdir} | awk '{sum+=$5}END{print sum}'`
if [ "$fastqsize" -gt "2592410750" ]
then
    threads="-t 12"
fi

testname=`ls -l ${fastqdir} | awk 'NR==1{print $9}'`
if [ ${testname: -3} == ".gz" ]
then
    read1=${splitdir}"/*${read1str}*.fastq.gz"
else
    read1=${splitdir}"/*${read1str}*.fastq"
fi

qsub -o ${topDir}/uger.out -j y -q $queue -r y -N ${groupname}cmd <<EOF
  echo "$0 $@"
EOF

## Not in merge, dedup,  or final stage, i.e. need to split and align files.
if [ -z $merge ] && [ -z $final ] && [ -z $dedup ]; then

    echo -e "(-: Aligning files matching $fastqdir\n in queue $queue to genome $genomeID with site file $site_file"

    ## Split fastq files into smaller portions for parallelizing alignment 
    ## Do this by creating a text script file for the job on STDIN and then 
    ## sending it to the cluster
    if [ ! $splitdirexists ]; then
        echo "(-: Created $splitdir and $outputdir.  Splitting files"
 
        if [ -n "$threads" ]
        then
            for i in ${fastqdir}
            do
		            filename=$(basename $i)
		            filename=${filename%.*}      

                qsub -o ${topDir}/uger.out -j y -q $queue -r y -N ${groupname}split${countjobs} -sync y <<- SPLITEND
                #!/bin/bash
                source $usePath
                $load_coreutils
                echo "Split file: $filename"
                split -a 3 -l $splitsize -d --additional-suffix=.fastq $i $splitdir/$filename
SPLITEND
						    wait
		            ARRAY[countjobs]="${groupname}split${countjobs}"
		            countjobs=$(( $countjobs + 1 ))
            done 

            ## List of split jobs to wait for
            for (( i=0; i < countjobs; i++ ))
            do
                if [ $i -eq 0 ]; then
                    holdjobs="${ARRAY[i]}"
                else
                    holdjobs="${holdjobs},${ARRAY[i]}"
                fi
            done
        else
            cp ${fastqdir} ${splitdir}
            wait
        fi
    else
        ## No need to re-split fastqs if they already exist
        echo -e "---  Using already created files in $splitdir\n"
    fi

    ## Launch job. Once split/move is done, set the parameters for the launch. 

    echo "(-: Starting job to launch other jobs once splitting is complete"

    ## Loop over all read1 fastq files and create jobs for aligning read1,
    ## aligning read2, and merging the two. Keep track of merge names for final 
    ## merge. When merge jobs successfully finish, can launch final merge job.  

    countjobs=0
    declare -a ARRAY

    for i in ${read1}
    do
	      ext=${i#*$read1str}
	      name=${i%$read1str*} 
        # these names have to be right or it'll break
	      name1=${name}${read1str}
	      name2=${name}${read2str}	
        jname=$(basename $name)${ext}
        usegzip=0
        if [ ${ext: -3} == ".gz" ]
        then
            usegzip=1
        fi
        qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}${jname}countligations -v ARG1=${usegzip},name=${name},name1=${name1},name2=${name2},ext=${ext},ligation=${ligation} ${juiceDir}/scripts/countligations.sh
        # align read1 fastq
        if [ $shortread ] || [ $shortreadend -eq 1 ]
        then
 		        alloc_mem=16
        else
 		        alloc_mem=12
        fi	
#-pe smp 12
        qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_align1${jname} -l m_mem_free=${alloc_mem}g <<- ALGNR1
        #!/bin/bash 
        source $usePath
        $load_bwa
        # Align read1 
        if [ $shortread ] || [ $shortreadend -eq 1 ]
        then		
            echo 'Running command bwa aln -q 15 $refSeq $name1$ext > $name1$ext.sai && bwa samse $refSeq $name1$ext.sai $name1$ext > $name1$ext.sam'
            bwa aln -q 15 $refSeq $name1$ext > $name1$ext.sai && bwa samse $refSeq $name1$ext.sai $name1$ext > $name1$ext.sam
  	        if [ \$? -ne 0 ]
  	        then 
  	            exit 100
  	        else
  			        echo "(-: Short align of $name1$ext.sam done successfully"
  	        fi		
			
        else
            echo 'Running command bwa mem $threads $refSeq $name1$ext > $name1$ext.sam '
            bwa mem $threads $refSeq $name1$ext > $name1$ext.sam
  	        if [ \$? -ne 0 ]
  	        then 
  	            exit 100
  	        else
  			        echo "(-: Mem align of $name1$ext.sam done successfully"
  	        fi		
        fi
ALGNR1

 	      # align read2 fastq
 	      if [ $shortread ] || [ $shortreadend -eq 2 ]
 	      then
 		        alloc_mem=16
 	      else
 		        alloc_mem=12
 	      fi	
#-pe smp 12
	      qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_align2${jname} -l m_mem_free=${alloc_mem}g <<- ALGNR2
 		    #!/bin/bash 
        source $usePath
        $load_bwa
 		    # Align read2
 		    if [ $shortread ] || [ $shortreadend -eq 2 ]
 		    then		
            echo 'Running command bwa aln -q 15 $refSeq $name2$ext > $name2$ext.sai && bwa samse $refSeq $name2$ext.sai $name2$ext > $name2$ext.sam '
 			      bwa aln -q 15 $refSeq $name2$ext > $name2$ext.sai && bwa samse $refSeq $name2$ext.sai $name2$ext > $name2$ext.sam
 			      if [ \$? -ne 0 ]
 			      then 
 				        exit 100
 			      else
 				        echo "(-: Short align of $name2$ext.sam done successfully"
 			      fi		
			
 		    else	
            echo 'Running command bwa mem $threads $refSeq $name2$ext > $name2$ext.sam'
 			      bwa mem $threads $refSeq $name2$ext > $name2$ext.sam
 			      if [ \$? -ne 0 ]
 			      then 
 				        exit 100
 			      else
 				        echo "(-: Mem align of $name2$ext.sam done successfully"
 			      fi		
 		    fi		
ALGNR2
 	      # wait for top two, merge
	      qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_merge${jname} -l m_mem_free=8g -hold_jid ${groupname}_align1${jname},${groupname}_align2${jname}  <<- MRGALL
 		    #!/bin/bash 
 		    export LC_ALL=C
		
 		    # sort read 1 aligned file by readname 
 		    sort -k1,1 $name1$ext.sam > $name1${ext}_sort.sam
 		    if [ \$? -ne 0 ]
 		    then 
 			      echo "***! Error while sorting $name1$ext.sam"
 			      exit 100
 		    else
 			      echo "(-: Sort read 1 aligned file by readname completed."
 		    fi
		
 		    # sort read 2 aligned file by readname 
 		    sort -k1,1 $name2$ext.sam > $name2${ext}_sort.sam
 		    if [ \$? -ne 0 ]
 		    then
            echo "***! Error while sorting $name2$ext.sam"			 
 			      exit 100
 		    else
 			      echo "(-: Sort read 2 aligned file by readname completed."
 		    fi
 		    # remove header, add read end indicator to readname
 		    awk 'NF >= 11{\$1 = \$1"/1";print}' $name1${ext}_sort.sam > $name1${ext}_sort1.sam
 		    awk 'NF >= 11{\$1 = \$1"/2";print}' $name2${ext}_sort.sam > $name2${ext}_sort1.sam
		
 		    # merge the two sorted read end files
 		    sort -k1,1 -m $name1${ext}_sort1.sam $name2${ext}_sort1.sam > $name$ext.sam
 		    if [ \$? -ne 0 ]
 		    then
            echo "***! Failure during merge of read files"			
 			      exit 100
 		    else
 			      rm $name1$ext.sa* $name2$ext.sa* $name1${ext}_sort*.sam $name2${ext}_sort*.sam
 			      echo "$name$ext.sam created successfully."
 		    fi 
MRGALL
	      qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -hold_jid ${groupname}_merge${jname} -l m_mem_free=8g -N ${groupname}_chimeric${jname}  <<- CHIMERIC
        #!/bin/bash                   
        export LC_ALL=C
		
 		    # call chimeric_blacklist.awk to deal with chimeric reads; sorted file is sorted by read name at this point
 		    awk -v "fname1"=$name${ext}_norm.txt -v "fname2"=$name${ext}_abnorm.sam -v "fname3"=$name${ext}_unmapped.sam -f ${juiceDir}/scripts/chimeric_blacklist.awk $name$ext.sam
		
        if [ \$? -ne 0 ]                                              
        then                                       
            echo "***! Failure during chimera handling of $name${ext}"
            exit 100                                                     
        fi  

 		    # if any normal reads were written, find what fragment they correspond to and store that
 		    if [ -e "$name${ext}_norm.txt" ]
 		    then  
 			      ${juiceDir}/scripts/fragment.pl $name${ext}_norm.txt $site_file > $name${ext}.frag.txt
			      if [ \$? -ne 0 ] 
            then                                                                                  
               echo "***! Failure during fragment assignment of $name${ext}"
               exit 100 
            fi
 			      # sort by chromosome, fragment, strand, and position
 			      sort -k2,2d -k6,6d -k4,4n -k8,8n -k1,1n -k5,5n -k3,3n $name${ext}.frag.txt > $name${ext}.sort.txt
            if [ \$? -ne 0 ]
            then                                                                        
               echo "***! Failure during sort of $name${ext}"
               exit 100                                                        
            else
 			         rm $name${ext}_norm.txt $name${ext}.frag.txt
            fi
 		    fi	
CHIMERIC
        ARRAY[countjobs]="${groupname}_chimeric${jname}"
        countjobs=$(( $countjobs + 1 ))
    done # done looping over all fastq split files

   # list of all jobs.  hold next steps until they have finished
    for (( i=0; i < countjobs; i++ ))
    do
        if [ $i -eq 0 ]; then
            holdjobs="-hold_jid ${ARRAY[i]}"
        else
            holdjobs="${holdjobs},${ARRAY[i]}"
        fi
    done    
fi

if [ -z $final ] && [ -z $dedup ]
then
    # merge the sorted files into one giant file that is also sorted.
    # note that if the $merge flag is set, this will run with $holdjobs empty
	  qsub -o ${topDir}/uger.out -j y -q ${long_queue} -r y -N ${groupname}_fragmerge -l m_mem_free=16g $holdjobs <<- MRGSRT
 	  export LC_ALL=C
    if [ -d $donesplitdir ]
    then
       mv $donesplitdir/* $splitdir/.
    fi

  	if ! sort -T  $tmpdir -m -k2,2d -k6,6d -k4,4n -k8,8n -k1,1n -k5,5n -k3,3n $splitdir/*.sort.txt  > $outputdir/merged_sort.txt
 	  then 
 		    echo "***! Some problems occurred somewhere in creating sorted align files."
  	else
    		echo "(-: Finished sorting all sorted files into a single merge."
        rm -r ${tmpdir}
  	fi
MRGSRT
    if [ ! -z $merge ]
    then
        holdjobs="-hold_jid ${groupname}_fragmerge";
    else
        holdjobs="$holdjobs,${groupname}_fragmerge";
    fi
fi

# Remove the duplicates from the big sorted file
if [ -z $final ]
then

	  qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_osplit $holdjobs <<- DEDUP
    source $usePath
    $load_cluster
 	  awk -v queue=$long_queue -v outfile=$topDir/uger.out -v juicedir=${juiceDir} -v dir=$outputdir -v groupname=$groupname -f ${juiceDir}/scripts/split_rmdups.awk $outputdir/merged_sort.txt
DEDUP
    if [ ! -z $dedup ]
    then
        holdjobs="-hold_jid ${groupname}_osplit,${groupname}_rmsplit"; 
    else
        holdjobs="$holdjobs,${groupname}_osplit,${groupname}_rmsplit";
    fi
fi

if [ -z "$genomePath" ]
then
 	#If no path to genome is give, use genome ID as default.
 	  genomePath=$genomeID
fi
# if early exit, we stop here, once the merged_nodups.txt file is created.
if [ -z "$earlyexit" ]
then
    qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_finallaunch $holdjobs <<- DOSTAT
    #!/bin/bash 
 		echo "(-: Alignment and merge done, launching other jobs."
    source $usePath
    $load_cluster
    qsub -o $topDir/uger.out -q $long_queue -l m_mem_free=16g -N ${groupname}_stats -j y -r y $holdjobs <<- EOF  
source $usePath; $load_java; export _JAVA_OPTIONS=-Xmx16384m; export LC_ALL=en_US.UTF-8; echo 'Experiment description: $about' > $outputdir/inter.txt; ${juiceDir}/scripts/statistics.pl -s $site_file -l $ligation -o $outputdir/stats_dups.txt $outputdir/dups.txt; cat $splitdir/*.res.txt | awk -f ${juiceDir}/scripts/stats_sub.awk >> $outputdir/inter.txt; java -cp ${juiceDir}/scripts/ LibraryComplexity $outputdir inter.txt >> $outputdir/inter.txt; ${juiceDir}/scripts/statistics.pl -s $site_file -l $ligation -o $outputdir/inter.txt -q 1 $outputdir/merged_nodups.txt; cat $splitdir/*_abnorm.sam > $outputdir/abnormal.sam; cat $splitdir/*_unmapped.sam > $outputdir/unmapped.sam
EOF
   qsub -o $topDir/uger.out -q $long_queue -l m_mem_free=16g -N ${groupname}_hic -hold_jid ${groupname}_stats -j y -r y <<- EOF 
source $usePath; $load_java; export _JAVA_OPTIONS=-Xmx16384m; ${juiceDir}/scripts/juicebox pre -f $site_file -s $outputdir/inter.txt -g $outputdir/inter_hists.m -q 1 $outputdir/merged_nodups.txt $outputdir/inter.hic $genomePath ;
EOF
 	qsub -o $topDir/uger.out -q $long_queue -l m_mem_free=16g -N ${groupname}_hic30 -j y -r y $holdjobs <<- EOF 
source $usePath; $load_java; export _JAVA_OPTIONS=-Xmx16384m; export LC_ALL=en_US.UTF-8; echo 'Experiment description: $about' > $outputdir/inter_30.txt; cat $splitdir/*.res.txt | awk -f ${juiceDir}/scripts/stats_sub.awk >> $outputdir/inter_30.txt; java -cp ${juiceDir}/scripts/ LibraryComplexity $outputdir inter_30.txt >> $outputdir/inter_30.txt; ${juiceDir}/scripts/statistics.pl -s $site_file -l $ligation -o $outputdir/inter_30.txt -q 30 $outputdir/merged_nodups.txt; export _JAVA_OPTIONS=-Xmx8192m; ${juiceDir}/scripts/juicebox pre -f $site_file -s $outputdir/inter_30.txt -g $outputdir/inter_30_hists.m -q 30 $outputdir/merged_nodups.txt $outputdir/inter_30.hic $genomePath
EOF
DOSTAT
   qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_postprocessing -hold_jid ${groupname}_finallaunch -cwd <<- POSTPROC
    source $usePath
    $load_cluster 
    qsub -o $topDir/uger.out -q $long_queue -l m_mem_free=16g -j y -N ${groupname}_postproc -hold_jid ${groupname}_hic30 -cwd <<-EOF
    source $usePath; 
    $load_java; 
    export _JAVA_OPTIONS=-Xmx16384m; 
    export LC_ALL=en_US.UTF-8; 
    ${juiceDir}/scripts/juicer_postprocessing.sh -j ${juiceDir}/scripts/juicebox -i $outputdir/inter_30.hic -m ${juiceDir}/references/motif -g $genomeID
EOF
POSTPROC

   holdjobs="-hold_jid ${groupname}_hic30,${groupname}_hic,${groupname}_stats,${groupname}_postproc"
   qsub -o ${topDir}/uger.out -j y -q ${queue} -r y -N ${groupname}_done -hold_jid ${groupname}_finallaunch <<- FINCLN2
    source $usePath
    $load_cluster
 		qsub -o $topDir/uger.out -q $queue -j y -N ${groupname}_prep_finalize -v splitdir=${splitdir},outputdir=${outputdir} $holdjobs ${juiceDir}/scripts/check.sh
FINCLN2
else
 		qsub -o $topDir/uger.out -q $queue -j y -N ${groupname}_done -v splitdir=${splitdir},outputdir=${outputdir} $holdjobs ${juiceDir}/scripts/check.sh
fi
echo "(-: Finished adding all jobs... please wait while processing."

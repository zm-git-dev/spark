#!/usr/bin/env perl

use strict;
use warnings;
use Carp;
use IO::File;
use Cwd qw|abs_path|;
#use Inline::Files;
use FindBin qw|$Bin|;
use Data::Dumper;
use List::Util qw|min max|;
use List::MoreUtils qw|uniq|;
use POSIX qw|floor ceil|;
use Perl6::Slurp;
use Getopt::Lucid qw|:all|;
use Config::Std;
use Utils::Hash qw|merge_conf|;
use Utils::File qw|count_lines|;
use Utils::Workflow;


use lib "$Bin/../lib/";
use Shared qw|read_list comb_intervals|;


############################
## Command line interface ##
############################

my @spec =  (
	Param("conf|c")->valid(sub { -r }),
	List("list|v")->valid(sub { -r }),
	Param("bed|b")->valid(sub { -r }),
	Param("rename")->valid(sub { -r }),
	Param("remove")->valid(sub { -r }),
	Param("prefix"),
	Param("outdir|out"),
	Param("engine|eng")->valid(sub { $_ eq 'SGE' || $_ eq 'BASH' }),
	Keypair("param|par"),
	Switch("help|h"),
	Switch("nomerge"),
	Switch("bychr"),
	Switch("dryrun|dry"),
	Switch("force")
	);

my $opt = Getopt::Lucid->getopt(\@spec);

if ($opt->get_help) {
	print STDERR <<EOF;
Purpose:
	This is a pipeline script to perform joint genotyping of gVCF files in large cohort.

Usages:
	gvcf_gt.pl --conf Config --list Batch_1.list --list Batch_2.list --out RootDir

Options:
	--list:	gVCF file list or directory. The list should have 1 or 2 columns per line. Path to gVCF 
			(required) and sample ID. If only one column is available, sample ID will be taken from 
			file basename after removing suffix. This option can be specified multiple times. Only file 
			name suffix '.g.vcf.gz' is considered valid. 
    --bed: 	This option specifies the targeted regions. It will override the PATH.TARGETS in config file.
    		The provided intervals must be sorted and non-overlapping, and should include padding if padding is needed.
    		The chromsome in the interval file must be in numerical order. 
    		Targeted regions are mainly used for split genotyping tasks.
    --nomerge: Do not merge the split VCFs, recommended for large VCF files.
    --bychr:  Group intervals by chromosome, recommended for targeted sequencing with small target size.
    --prefix: Prefix for output VCF files, default: "cohort".
   	--rename: Sample rename list.
	--remove: A list of bad samples to be removed.

Notes:
	This scripts implements GATK4's two-step (genomic DB-import + typing) approach for joint genotyping, which is 
	suitable for genotyping large sample sizes. The input gVCF files can only contain one sample in each file. The 
	sample IDs for input gVCFs should be unique. 
	
	The targeted regions will be split into multiple dynamically merged intervals based on sample size and number of
	intervals. Then genomic DB import and genotyping will be run in parallel for each split.

Dependencies:
	gatk (v4), bcftools, tabix.

EOF
	exit 1;
}

$opt->validate({ requires => [qw|conf list outdir|] });

my $rootdir = $opt->get_outdir;

my %conf = merge_conf($opt->get_conf, $opt->get_param); 
if (defined $opt->get_bed) {
	$conf{PATH}{TARGETS} = abs_path($opt->get_bed);
}
else {
	unless(exists $conf{PATH}{TARGETS}) {
		croak "Cannot find targeted intervals";
	}
}
while(my ($label, $path) = each %{$conf{PATH}}) {
	next if $label =~ /DIR$/;
	unless (-f $path) {
		croak "Cannot find $label file $path";
	}
}

my $prefix;
if ($opt->get_prefix) {
	$prefix = $opt->get_prefix;
	croak "Output prefix cannot contain path separator" if $prefix =~ /\//;
}
else {
	$prefix = "cohort";
}
$conf{PATH}{PREFIX} = $prefix;

############################
## Config file parsing    ##
## Input files validation ##
############################

# Read and check gVCF files
my %id2gvcf;
foreach my $list ($opt->get_list) {
	my $gvcfs = read_list($list, { suffix => "g.vcf.gz", remove => $opt->get_remove, rename => $opt->get_rename });
	while(my ($iid, $filepath) = each %$gvcfs) {
		if (defined $id2gvcf{$iid}) {
			croak "gVCF for $iid was already included, use rename to change IID";
		}
		$id2gvcf{$iid} = $filepath;
	}
}

my @samps = sort keys %id2gvcf;

unless (@samps) {
	print STDERR "No sample was found\n";
	exit 1;
}
else {
	print "Total number of samples: ", scalar(@samps), "\n";
}

# Analyze the targeted intervals to determine the split intervals.
my ($merged, $original);
if ($opt->get_bychr) {
	print STDERR "Group original intervals by chromosome\n";
	($merged, $original) = comb_intervals($conf{PATH}{TARGETS});
}
else {
	my $numintv = count_lines($conf{PATH}{TARGETS});
	my $possible_mergecnt = int($numintv/@samps/2.5);
	my $mergecnt = $possible_mergecnt > 1 ? $possible_mergecnt : 1;
	if ($mergecnt > 1) {
		print STDERR "Will merge ~$mergecnt original intervals into each new interval for DB-import.\n";
	}
	else {
		print STDERR "Will process one interval at a time for DB-import.\n"
	}
	($merged, $original) = comb_intervals($conf{PATH}{TARGETS}, $mergecnt);
}
print STDERR "The final number of merged intervals: ", scalar(@$merged), "\n";
$conf{RSRC}{NSPLITS} = scalar(@$merged);

##############################
## Workflow initialization  ##
## Working directory setup  ##
##############################

my $wkf = Utils::Workflow->new($rootdir, { engine => $opt->get_engine, force => $opt->get_force } );

# Writing sample name maps and intervals
open my $fout, ">$rootdir/par/SAMPMAP" or die "Cannot write SAMPMAP";
foreach my $iid (@samps) {
	print $fout $iid, "\t", $id2gvcf{$iid}, "\n";
}

open my $flst, ">$rootdir/out/intervals.list" or die "Cannot write to intervals list";
for(my $ii = 0; $ii < @$merged; $ii ++) {
	printf $flst "%s:%d-%d\n", @{$merged->[$ii]};
	my $jj = $ii + 1;
	open my $fout, ">$rootdir/par/INTERVAL.$jj" or die "Cannot write to INTERVAL.$jj";
	printf $fout "%s:%d-%d\n", @{$merged->[$ii]};
	open my $flst, ">$rootdir/par/INTERVALS.$jj.bed" or die "Cannot write to INTERVALS.$jj.bed";
	foreach my $intv (@{$original->[$ii]}) {
		print $flst join("\t", @$intv), "\n";
	}
}

# Validate the split intervals
{
	my $input_intervals = join("\n", map { (split)[0,1,2] } slurp $conf{PATH}{TARGETS});
	my @refmt_beds;
	for(my $jj = 1; $jj <= @$merged; $jj ++) {
		push @refmt_beds, map { (split)[0,1,2] } slurp "$rootdir/par/INTERVALS.$jj.bed";
	}
	my $refmt_intervals = join("\n", @refmt_beds);

	unless ($input_intervals eq $refmt_intervals) {
		croak "Input and reformatted intervals are different!";
	}
}

# Write runtime config
write_config %conf, "$rootdir/par/run.conf" unless $opt->get_dryrun; 

# Add workflow jobs
#	$wkf->add(import_gvcfs(), { name => "DBImport", nslots => scalar(@$merged),
#			expect => [ map { "wrk/$prefix.$_/__tiledb_workspace.tdb" } 1..scalar(@$merged) ] })

$wkf->add(genotyping(), { name => "Genotyping", nslots => scalar(@$merged), 
#		depend => "DBImport", deparray => 1,
		expect => [ map { ["wrk/$prefix.$_.vcf.gz", 
						   "wrk/$prefix.$_.vcf.gz.tbi"] } 1..scalar(@$merged) ] });
unless ($opt->get_nomerge) {
	$wkf->add(gather_vcfs(), { name => "GatherVcfs", depend => "Genotyping",
			expect => ["out/$prefix.vcf.gz", "out/$prefix.vcf.gz.tbi"] });
}


$wkf->inst(\%conf);
$wkf->run({ conf => $conf{$wkf->{engine}},  dryrun => $opt->get_dryrun });


############################
## Workflow components    ##
############################

# Note: there are many options to optimize GenomicDBImport, but may dependent on the platform
sub import_gvcfs {
	my $script = <<'EOF';

read REGION < _PARDIR_/INTERVAL._INDEX_

rm -fR _WRKDIR_/_PATH.PREFIX_._INDEX_

gatk --java-options "_RSRC.GATKOPT4DBIMPORT_" \
	GenomicsDBImport \
	--genomicsdb-workspace-path _WRKDIR_/_PATH.PREFIX_._INDEX_ \
	--sample-name-map _PARDIR_/SAMPMAP \
	-L $REGION _DBIMPORT.OPTION[ \
	]_

EOF
	return $script;
}

# We now merged import and genotyping in one step
# we will clean up the DB directory once the genotying is done
sub genotyping {
	my $script = <<'EOF';

read REGION < _PARDIR_/INTERVAL._INDEX_

rm -fR _GENOMEDBDIR_/_PATH.PREFIX_._INDEX_

gatk --java-options "_RSRC.GATKOPT4DBIMPORT_" \
	GenomicsDBImport \
	--genomicsdb-workspace-path _GENOMEDBDIR_/_PATH.PREFIX_._INDEX_ \
	--sample-name-map _PARDIR_/SAMPMAP \
	-L $REGION _DBIMPORT.OPTION[ \
	]_

gatk --java-options "_RSRC.GATKOPT_" \
	GenotypeGVCFs \
	-R _PATH.FASTA_ \
	-O _WRKDIR_/_PATH.PREFIX_._INDEX_.vcf.gz \
	-D _PATH.DBSNP_ \
	-G StandardAnnotation \
	--only-output-calls-starting-in-intervals \
    -new-qual \
    -V gendb://_GENOMEDBDIR_/_PATH.PREFIX_._INDEX_ \
    -L _PARDIR_/INTERVALS._INDEX_.bed _GENOTYPING.OPTION[ \
    ]_

rm -fR _GENOMEDBDIR_/_PATH.PREFIX_._INDEX_

EOF
	if (exists $conf{PATH}{DBDIR}) {
		$script =~ s/_GENOMEDBDIR_/$conf{PATH}{DBDIR}/g;
	}
	else {
		$script =~ s/_GENOMEDBDIR_/_WRKDIR_/g;
	}
	return $script;
}

#sub gather_vcfs {
#	my $script = <<'EOF';

#INPUTS=$(perl -e 'print join(" ", map { "I=_WRKDIR_/_PATH.PREFIX_.$_.vcf.gz" } 1.._RSRC.NSPLITS_)')

#picard _RSRC.PICARDOPT_ GatherVcfs \
#	O=_OUTDIR_/_PATH.PREFIX_.vcf.gz \
#	$INPUTS

#tabix -p vcf _OUTDIR_/_PATH.PREFIX_.vcf.gz

#EOF
#}

sub gather_vcfs {
	my $script = << 'EOF';

perl -e 'print join("\n", map { "_WRKDIR_/_PATH.PREFIX_.$_.vcf.gz" } 1.._RSRC.NSPLITS_), "\n"' \
	> _TMPDIR_/vcf_list.txt

bcftools concat -f _TMPDIR_/vcf_list.txt -D -O z -o _OUTDIR_/_PATH.PREFIX_.vcf.gz

tabix -f -p vcf _OUTDIR_/_PATH.PREFIX_.vcf.gz

EOF
}

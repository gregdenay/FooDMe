#!/usr/bin/env python3

import argparse
import os, sys
import datetime
import subprocess

DB = os.path.join(os.path.dirname(__file__), 'db/')

def git_version():	
	try:
		version = subprocess.check_output(["git", "describe", "--always"], cwd= os.path.join(sys.path[0],"")).strip().decode("utf-8")
	except subprocess.CalledProcessError:
		version = "Unknown"
	finally:
		return(version)

def create_config(config_file, args):
	if os.path.exists(config_file):
		print("\nWARNING: The file "+config_file+" already exists. It will be replaced.\n")
		os.remove(config_file)
	else:
		print("\nCreating config file.\n")
	
	indent1 = " "*4

	with open(config_file, 'w') as conf:
		# File metadata
		conf.write("# This config file was automatically generated by foodme.py\n")
		conf.write("# Version : {}\n".format(git_version()))
		conf.write("# Date: {}\n".format(datetime.datetime.now()))
				
		# Workflow parameters
		conf.write("workdir: {}\n".format(args.working_directory))
		conf.write("samples: {}\n".format(args.sample_list))
		conf.write("threads_sample: {}\n".format(args.threads_sample))
		conf.write("threads: {}\n".format(args.threads))
		
		# Fastp
		conf.write("fastp:\n")
		conf.write("{}length_required: {}\n".format(indent1, args.fastp_length))
		conf.write("{}qualified_quality_phred: {}\n".format(indent1, args.fastp_min_phred))
		conf.write("{}window_size: {}\n".format(indent1, args.fastp_window))
		conf.write("{}mean_quality: {}\n".format(indent1, args.fastp_meanq))
		
		# Read filter
		conf.write("read_filter:\n")
		conf.write("{}min_length: {}\n".format(indent1, args.merge_minlength))
		conf.write("{}max_length: {}\n".format(indent1, args.merge_maxlength))
		conf.write("{}max_expected_errors: {}\n".format(indent1, args.merge_maxee))
		conf.write("{}max_ns: {}\n".format(indent1, args.merge_maxns))
		
		# Cluster
		conf.write("cluster:\n")
		conf.write("{}method: {}\n".format(indent1, args.clustering))
		conf.write("{}cluster_identity: {}\n".format(indent1, args.cluster_id))
		conf.write("{}cluster_minsize: {}\n".format(indent1, args.cluster_minsize))
		
		# Chimera
		conf.write("chimera:\n")
		conf.write("{}denovo: {}\n".format(indent1, args.chim_denovo))
		conf.write("{}chimera_DB: {}\n".format(indent1, args.chim_ref))
		
		# Taxonomy
		conf.write("taxonomy:\n")
		conf.write("{}method: {}\n".format(indent1, args.tax))
		conf.write("{}rankedlineage_dmp: {}\n".format(indent1, args.rankedlineage_dmp))
		conf.write("{}nodes_dmp: {}\n".format(indent1, args.nodes_dmp))
		
		# Sintax
		conf.write("sintax:\n")
		conf.write("{}sintax_db: {}\n".format(indent1, args.sintaxdb))
		conf.write("{}sintax_cutoff: {}\n".format(indent1, args.sintax_cutoff))
		
		# Blast
		conf.write("blast:\n")
		conf.write("{}blast_DB: {}\n".format(indent1, args.blastdb))
		conf.write("{}taxdb: {}\n".format(indent1, args.taxdb))
		conf.write("{}e_value: {}\n".format(indent1, args.blast_eval))
		conf.write("{}perc_identity: {}\n".format(indent1, args.blast_id))
		conf.write("{}qcov: {}\n".format(indent1, args.blast_cov))
		conf.write("{}bit_score_diff: {}\n".format(indent1, args.bitscore))
	
def run_snakemake(config_file, args):
	forceall = ("--forceall" if args.forceall else "")
	dryrun = ("-n" if args.dryrun else "")
	conda_prefix= ("--conda-prefix {}".format(args.condaprefix) if args.condaprefix else "")
	notemp = ("" if args.clean_temp else "--notemp")
	call = "snakemake -s {snakefile} --configfile {config_file} --use-conda --cores {cores} {conda_prefix} {notemp} {forceall} {dryrun}".format(snakefile= args.snakefile,
																																				config_file= config_file,
																																				conda_prefix= conda_prefix,
																																				forceall= forceall,
																																				dryrun = dryrun,
																																				cores=args.threads,
																																				notemp=notemp)
	print(call)
	subprocess.call(call, shell=True)
	
def main(): 
	
	# Action classes to check input parameters
	class FractionType(argparse.Action):
		def __call__(self, parser, namespace, values, option_string=None):
			if values < 0 or values > 1:
				parser.error("Invalid value: '" + self.dest + "' must be between 0 and 1.")
			setattr(namespace, self.dest, values)
	
	class PercentType(argparse.Action):
		def __call__(self, parser, namespace, values, option_string=None):
			if values < 0 or values > 100:
				parser.error("Invalid value: '" + self.dest + "' must be between 0 and 100.")
			setattr(namespace, self.dest, values)
	
	class DatabaseType(argparse.Action):
		def __call__(self, parser, namespace, values, option_string=None):
			if values and not os.path.exists(values):
				parser.error("'" + self.dest + "' not found: '" + values + "' does not exist.")
			setattr(namespace, self.dest, values)
	
	parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter, prog = "FooDMe", description= "Another pipeline for (Food) DNA metabarcoding")
	parser.add_argument('-v', '--version', action='version', version="FooDMe version: "+ git_version(), help="Print pipeline version and exit")
	
	# Path arguments
	ioargs = parser.add_argument_group('I/O path arguments')
	ioargs.add_argument('-l', '--sample_list', required=True, type=os.path.abspath, 
						help="Tab-delimited list of samples and paths to read files. Must contain one line of header, each further line contains sample_name, read1_path, read2_path")
	ioargs.add_argument('-d', '--working_directory', required=True, type=os.path.abspath,
						help="Directory to create output files")
						
	# Snakemake arguments
	smkargs = parser.add_argument_group('Snakemake arguments')
	smkargs.add_argument('--forceall', required=False, default=False, action='store_true',
						help="Force the recalculation of all files")
	smkargs.add_argument('-n', '--dryrun', required=False, default=False, action='store_true',
						help="Dryrun. Create config file and calculate the DAG but do not execute anything")
	smkargs.add_argument('-T', '--threads', required=False, default=8, type=int,
						help="Maximum number of threads to use")
	smkargs.add_argument('-t', '--threads_sample', required=False, default=1, type=int,
						help="Number of threads to use per concurent job")
	smkargs.add_argument('-c', '--condaprefix', required=False, type=os.path.abspath, default=False,
						help="Location of stored conda environment. Allows snakemake to reuse environments.")
	smkargs.add_argument('-s', '--snakefile', required=False, type=os.path.abspath, default=os.path.join(sys.path[0], "Snakefile"),
						help="Path to the Snkefile in the FOodMe repo")
	smkargs.add_argument('--clean_temp', required=False, default= False, action='store_true',
						help="Remove large fasta and fastq files to save storage space")

	# Fastp
	fastpargs = parser.add_argument_group('Fastp options')
	fastpargs.add_argument('--fastp_length', required=False, default=50, type=int,
						help="Minimum length of input reads to keep")
	fastpargs.add_argument('--fastp_min_phred', required=False, default=15, type=int,
						help="Minimal quality value per base")
	fastpargs.add_argument('--fastp_window', required=False, default=4, type=int,
						help="Size of the sliding window for tail quality trimming")
	fastpargs.add_argument('--fastp_meanq', required=False, default=20, type=int,
						help="Minimum mean Phred-score in the sliding window for tail quality trimming")					
						
	# Read filter
	readargs = parser.add_argument_group('Merged reads filtering options')
	readargs.add_argument('--merge_minlength', required=False, default=75, type=int,
						help="Minimum length merged reads to keep")
	readargs.add_argument('--merge_maxlength', required=False, default=125, type=int,
						help="Maximum length merged reads to keep")
	readargs.add_argument('--merge_maxee', required=False, default=1, type=int,
						help="Maximum expected errors in merged reads to keep")
	readargs.add_argument('--merge_maxns', required=False, default = 0, type=int,
						help="Maximum number of 'N' base in merged reads")
	
	# Cluster
	clsargs = parser.add_argument_group('Clustering options')
	clsargs.add_argument('--clustering', required = False, default='distance', choices= ['distance', 'abundance'],
						help="Clustering method: Abundance- or Distance- Greedy Clutering")
	clsargs.add_argument('--cluster_id', required=False, default=0.97, type=float, action= FractionType,
						help="Minimum identity for clustering sequences in OTUs (between 0 and 1)")
	clsargs.add_argument('--cluster_minsize', required=False, default=2, type=int,
						help="Minimal size cutoff for clusters")
	
	# Chimera
	chimargs = parser.add_argument_group('Chimera detection options')
	chimargs.add_argument('--chim_denovo', required=False, default=False, action='store_true',
						help="Perform de novo chimera detection and filtering")
	chimargs.add_argument('--chim_ref', required=False, type=os.path.abspath, default=False, action = DatabaseType,
						help="Path to the database for chimera detection. If omitted, reference-based chimera filtering will be skipped.")

	#Taxonomy 
	taxo = parser.add_argument_group('Taxonomic assignement options')
	taxo.add_argument('--tax', required = False, choices = ['blast', 'sintax'], default = 'blast',
						help="Method for taxonomic assignement: BLAST or SINTAX")
	taxo.add_argument('--nodes_dmp', required=False, type=os.path.abspath, action = DatabaseType,
						default=os.path.join(DB, "taxdump/nodes.dmp"),
						help="Path to the nodes.dmp file")
	taxo.add_argument('--rankedlineage_dmp', required=False, type=os.path.abspath, action = DatabaseType,
						default=os.path.join(DB, "taxdump/rankedlineage.dmp"),
						help="Path to the names.dmp file")		
	
	# Sintax
	sintax = parser.add_argument_group('Options for SINTAX search and taxonomy consensus determination')
	sintax.add_argument('--sintaxdb', required = False, type= os.path.abspath, action = DatabaseType,
						default=os.path.join(DB, "sintax/mitochondrion.LSU.sintax.faa"),
						help="Path to the SINTAX database (FASTA)")
	sintax.add_argument('--sintax_cutoff', required=False, type= float, default= 0.8, action= FractionType,
						help="Bootstrap cutoff value for taxonomic support")
	
	# Blast
	blastargs = parser.add_argument_group('Options for BLAST search and taxonomy consensus determination')
	blastargs.add_argument('--blastdb', required=False, type=os.path.abspath, action = DatabaseType,
						default=os.path.join(DB, "blast/mitochondrion.LSU.faa"),
						help="Path to the BLAST database (FASTA)")
	blastargs.add_argument('--taxdb', required=False, type=os.path.abspath, action = DatabaseType,
						default=os.path.join(DB, "blast/"),
						help="Path to the BLAST taxonomy database (folder)")
	blastargs.add_argument('--blast_eval', required=False, default=1e-30, type=float,
						help="E-value threshold for blast results")
	blastargs.add_argument('--blast_id', required=False, default=97, type=float, action= PercentType,
						help="Minimal identity between the hit and query for blast results (in percent)")
	blastargs.add_argument('--blast_cov', required=False, default=97, type=float, action= PercentType,
						help="Minimal proportion of the query covered by a hit for blast results. A mismatch is still counting as covering (in percent)")
	blastargs.add_argument('--bitscore', required=False, default=4, type=int,
						help="Maximum bit-score difference with the best hit for a blast result to be included in the taxonomy consensus detemination")
	
	args = parser.parse_args()
	
	# SINTAX Warning
	if args.tax == 'sintax':
		input("WARNING! THe SINTAX algorithm returns only the first best hit in the database. This may lead to spurious assignement of ambiguous reads. Use at your own risk.\n Press Enter to continue or Ctrl-C to quit")
	
	# Create workdir
	if not os.path.exists(args.working_directory):
		os.makedirs(args.working_directory)
	
	# Create config.yaml
	config_file = os.path.join(args.working_directory, "config.yaml")
	create_config(config_file, args)

	# Execute snakemake
	run_snakemake(config_file, args)
	
	# On quit
	print("\nThank you for using FooDMe!\n")

if __name__=='__main__':
		main()
# TODO:
# =====
# Check and optimize parameters
# Make fancy mardown report
# Make unnescessary files temporary
# Compare database, evtl. curate by merging databases
# Compare OTU with ASV analyse

import pandas as pd
import os, json, csv

shell.executable("bash")
    
# Settings ---------------------------
 
configfile: "config.yaml"
workdir: config["workdir"]
 
samples = pd.read_csv(config["samples"], index_col="sample", sep = "\t")
samples.index = samples.index.astype('str', copy=False) # in case samples are integers, need to convert them to str

# Functions ------------------------------------------

def _get_fastq(wildcards,read_pair='fq1'):
    return samples.loc[(wildcards.sample), [read_pair]].dropna()[0]
    
# Rules ------------------------------
 
rule all:
    input: 
        # fastp
        expand("trimmed/{sample}_R1.fastq.gz", sample = samples.index),
        expand("trimmed/{sample}_R2.fastq.gz", sample = samples.index),
        # VSEARCH
        expand("{sample}/{sample}.derep.fasta", sample = samples.index),
        "VSEARCH/all.derep.fasta",
        "VSEARCH/otus.fasta",
        expand("{sample}/{sample}_otutab.tsv", sample = samples.index),
        # BLAST
        "blast/blast_search.tsv",    
        "blast/blast_filtered.tsv",
        # Taxonomy
        "blast/consensus_table.tsv",
        expand("{sample}/{sample}_composition.tsv", sample = samples.index),
        # Sample reports
        expand("trimmed/reports/{sample}.tsv", sample = samples.index),
        expand("{sample}/{sample}_qc_filtering_report.tsv", sample = samples.index),
        expand("{sample}/sequence_quality.stats", sample = samples.index),
        expand("{sample}/{sample}_mapping_report.tsv", sample = samples.index),
        expand("{sample}/{sample}_taxonomy_stats.tsv", sample = samples.index),
        expand("{sample}/{sample}_composition.tsv", sample = samples.index),
        expand("{sample}/{sample}_result_summary.tsv", sample = samples.index),
        expand("{sample}/{sample}_summary.tsv", sample = samples.index),
        # Global reports
        "reports/fastp_stats.tsv",
        "reports/qc_filtering_stats.tsv",
        "reports/clustering_stats.tsv",
        "reports/mapping_stats.tsv",
        "reports/blast_stats.tsv",
        "reports/taxonomy_stats.tsv",
        "reports/summary.tsv",
        "reports/result_summary.tsv",
        "reports/software_versions.tsv",
        "reports/db_versions.tsv",
        # Markdown
        "reports/summary.html"
        
# Fastp rules----------------------------
 
rule run_fastp:
    input:
        r1 = lambda wildcards: _get_fastq(wildcards, 'fq1'),
        r2 = lambda wildcards: _get_fastq(wildcards, 'fq2')
    output:
        r1 = "trimmed/{sample}_R1.fastq.gz",
        r2 = "trimmed/{sample}_R2.fastq.gz",
        json = "trimmed/reports/{sample}.json",
        html = "trimmed/reports/{sample}.html"
    params:
        length_required = config["fastp"]["length_required"],
        qualified_quality_phred = config["fastp"]["qualified_quality_phred"]
    threads: config["threads"]
    message: "Running fastp on {wildcards.sample}"
    conda: "envs/fastp.yaml"
    log: 
        "logs/{sample}_fastp.log"
    shell:
        "fastp -i {input.r1} -I {input.r2} -o {output.r1} -O {output.r2} -h {output.html} -j {output.json}\
        --length_required {params.length_required} --qualified_quality_phred {params.qualified_quality_phred} --detect_adapter_for_pe --thread {threads} --report_title 'Sample {wildcards.sample}' |\
        tee {log} 2>&1"

rule parse_fastp:
    input:
        json = "trimmed/reports/{sample}.json",
        html = "trimmed/reports/{sample}.html"
    output:
        tsv = "trimmed/reports/{sample}.tsv"
    message: "Parsing fastp json report"
    run:
        with open(input.json,'r') as handle:
            data = json.load(handle)
          
        link_path = os.path.join("..", input.html)
        header = "Sample\tTotal reads before\tTotal bases before\tTotal reads after\tTotal bases after\tQ20 rate after\tQ30 rate after\tDuplication rate\tInsert size peak\tlink_to_report"
        datalist = [wildcards.sample, data["summary"]["before_filtering"]["total_reads"],data["summary"]["before_filtering"]["total_bases"],data["summary"]["after_filtering"]["total_reads"],data["summary"]["after_filtering"]["total_bases"],data["summary"]["after_filtering"]["q20_rate"],data["summary"]["after_filtering"]["q30_rate"],data["duplication"]["rate"],data["insert_size"]["peak"], link_path]
        with open (output.tsv,"w") as outfile:
            outfile.write(header+"\n")
            writer=csv.writer(outfile, delimiter='\t')
            writer.writerow(datalist) 

rule collect_fastp_stats:
    input:
        expand('trimmed/reports/{sample}.tsv', sample=samples.index)
    output:
        "reports/fastp_stats.tsv"
    message: "Collecting fastp stats"
    shell:
        """
        cat {input[0]} | head -n 1 > {output}
        for i in {input}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        """
 
# Reads merging and quality filtering rules----------------------------

rule merge_reads:
    input:
        r1 = "trimmed/{sample}_R1.fastq.gz",
        r2 = "trimmed/{sample}_R2.fastq.gz"
    output:
        merged = "{sample}/{sample}.merged.fastq",
        notmerged_fwd = "{sample}/{sample}.notmerged.fwd.fasta",
        notmerged_rev = "{sample}/{sample}.notmerged.rev.fasta"
    threads: config["threads"]
    message: "Merging reads on {wildcards.sample}"
    conda: "envs/vsearch.yaml"
    log:
        "logs/{sample}_merge.log"
    shell:
        "vsearch --fastq_mergepairs {input.r1} --reverse {input.r2} --threads {threads} --fastqout {output.merged} \
        --fastq_eeout --fastaout_notmerged_fwd {output.notmerged_fwd} --fastaout_notmerged_rev {output.notmerged_rev} | \
        tee {log} 2>&1"       

rule qual_stat:
# Remove?
    input: 
        merged = "{sample}/{sample}.merged.fastq"
    output:
        stat = "{sample}/sequence_quality.stats"
    message: "Collecting quality statistics for {wildcards.sample}"
    conda: "envs/vsearch.yaml"
    shell:
        "vsearch --fastq_eestats {input.merged} --output {output.stat}"
        
rule quality_filter: 
    input: 
        merged = "{sample}/{sample}.merged.fastq"
    output:
        filtered = "{sample}/{sample}_filtered.fasta",
        discarded = "{sample}/{sample}_discarded.fasta"
    params:
        minlen= config["read_filter"]["min_length"],
        maxlen = config["read_filter"]["max_length"],
        maxee = config["read_filter"]["max_expected_errors"]
    message: "Quality filtering {wildcards.sample}"
    conda: "envs/vsearch.yaml"
    log:
        "logs/{sample}_filter.log"
    shell:
        "vsearch --fastq_filter {input.merged} --fastq_maxee {params.maxee} --fastq_minlen {params.minlen} --fastq_maxlen {params.maxlen}\
        --fastq_maxns 0 --fastaout {output.filtered} --fasta_width 0 --fastaout_discarded {output.discarded} |\
        tee {log} 2>&1"


rule dereplicate:
    input: 
        filtered = "{sample}/{sample}_filtered.fasta"
    output:
        derep = "{sample}/{sample}.derep.fasta"
    message: "Dereplicating {wildcards.sample}"
    conda: "envs/vsearch.yaml"
    log:
        "logs/{sample}_derep.log"
    shell:
        "vsearch --derep_fulllength {input.filtered} --strand plus --output {output.derep} --sizeout --relabel {wildcards.sample} --fasta_width 0 | tee {log} 2>&1"

rule qc_stats:
    input:
        merged = "{sample}/{sample}.merged.fastq",
        filtered = "{sample}/{sample}_filtered.fasta",
        notmerged_fwd = "{sample}/{sample}.notmerged.fwd.fasta",
        notmerged_rev = "{sample}/{sample}.notmerged.rev.fasta",
        discarded = "{sample}/{sample}_discarded.fasta",
        dereplicated = "{sample}/{sample}.derep.fasta"
    output:
        "{sample}/{sample}_qc_filtering_report.tsv"
    message: "Collecting quality filtering summary for {wildcards.sample}"
    shell:
        """
        # Parsing fasta/fastq files
        merged=$(grep -c "^@" {input.merged})
        notmerged=$(grep -c "^>" {input.notmerged_fwd})
        filtered=$(grep -c "^>" {input.filtered})
        discarded=$(grep -c "^>" {input.discarded})
        dereplicated=$(grep -c "^>" {input.dereplicated})
        # Calculating fractions
        reads_total=$(($merged + $notmerged))
        notmerged_perc=$(echo "scale=2;(100* $notmerged / $reads_total)" | bc)
        discarded_perc=$(echo "scale=2;(100* $discarded / $merged)" | bc)
        kept=$(echo "scale=2;(100* $filtered / $reads_total)" | bc)
        # Writing report
        echo "Sample\tTotal reads\tMerged reads\tMerging failures\tMerging failures [%]\tQuality filtered reads\tDiscarded reads\tDiscarded reads [%]\tNumber of unique sequences\tReads kept [%]" > {output}
        echo "{wildcards.sample}\t$reads_total\t$merged\t$notmerged\t$notmerged_perc\t$filtered\t$discarded\t$discarded_perc\t$dereplicated\t$kept" >> {output}
        """
        
rule collect_qc_stats:
    input:
        expand("{sample}/{sample}_qc_filtering_report.tsv", sample = samples.index)
    output:
        "reports/qc_filtering_stats.tsv"
    message: "Collecting quality filtering stats"
    shell:
        """
        cat {input[0]} | head -n 1 > {output}
        for i in {input}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        """
        
# Clustering rules----------------------------

rule merge_samples:
    input:
        expand("{sample}/{sample}.derep.fasta", sample = samples.index)
    output:
        "VSEARCH/all.fasta"
    message: "Merging samples"
    shell:
        """
        cat {input} > {output}
        """

rule derep_all:
    input:
        "VSEARCH/all.fasta"
    output:
        "VSEARCH/all.derep.fasta"
    conda: "envs/vsearch.yaml"
    message: "Dereplicating"
    log: 
        "logs/derep_all.log"
    shell:
        """
        vsearch --derep_fulllength {input} --sizein --sizeout --fasta_width 0 --output {output} | tee {log} 2>&1
        """
        
rule cluster:
    input: 
        "VSEARCH/all.derep.fasta"
    output:
        "VSEARCH/centroids.fasta"
    params:
        clusterID = config["cluster"]["cluster_identity"]
    conda: "envs/vsearch.yaml"
    threads: config["cores"]
    message: "Clustering sequences"
    log:
        "logs/clustering.log"
    shell:
        """
        vsearch --cluster_size {input} --threads {threads} --id {params.clusterID} --strand plus --sizein --sizeout --fasta_width 0 --centroids {output} | tee {log} 2>&1
        """
        
rule sort_all:
    input: 
        "VSEARCH/centroids.fasta"
    output:
        "VSEARCH/sorted.fasta"
    conda: "envs/vsearch.yaml"
    threads: config["cores"]
    message: "Sorting centroids and removing singleton"
    log:
        "logs/sort_all.log"
    shell:
        """
        vsearch --sortbysize {input} --threads {threads} --sizein --sizeout --fasta_width 0 --minsize 2 --output {output} | tee {log} 2>&1
        """
        
rule chimera_denovo:
    input:
        "VSEARCH/sorted.fasta"
    output:
        "VSEARCH/denovo.nonchimeras.fasta"
    conda: "envs/vsearch.yaml"
    message: "De novo chimera detection"
    log:
        "logs/denovo_chimera.log"
    shell:
        """
        vsearch --uchime_denovo {input} --sizein --sizeout --fasta_width 0 --qmask none --nonchimeras {output}| tee {log} 2>&1
        """
        
rule chimera_db:
    input:
        "VSEARCH/denovo.nonchimeras.fasta"
    output:
        "VSEARCH/nonchimeras.fasta"
    params:
        DB = config["cluster"]["chimera_DB"]
    threads: config["cores"]
    conda: "envs/vsearch.yaml"
    message: "Reference chimera detection"
    log:
        "logs/ref_chimera.log"
    shell:
        """
        vsearch --uchime_ref {input} --db {params.DB} --threads {threads} --sizein --sizeout --fasta_width 0 --qmask none --dbmask none --nonchimeras {output}| tee {log} 2>&1
        """

rule relabel_otu:
    input:
        "VSEARCH/nonchimeras.fasta"
    output:
        "VSEARCH/otus.fasta"
    conda: "envs/vsearch.yaml"
    message: "Relabelling OTUs"
    log:
        "logs/relabel_otus.log"
    shell:
        """
        vsearch --fastx_filter {input} --sizein --sizeout --fasta_width 0 --relabel OTU_ --fastaout {output} | tee {log} 2>&1
        """
        
rule clustering_stats:
    input:
        samples = expand("{sample}/{sample}.derep.fasta", sample = samples.index),
        all = "VSEARCH/all.fasta",
        derep = "VSEARCH/all.derep.fasta",
        centroids = "VSEARCH/centroids.fasta",
        nonsinglet = "VSEARCH/sorted.fasta",
        non_chimera_denovo = "VSEARCH/denovo.nonchimeras.fasta",
        non_chimera_db = "VSEARCH/nonchimeras.fasta"
    output:
        "reports/clustering_stats.tsv"
    message: "Collecting clustering stats"
    shell:
        """
        # Collecting counts
        samples=({input.samples})
        n_samples=${{#samples[@]}}
        all=$(grep "^>" {input.all} | awk -F '=' '{{s+=$2}}END{{print s}}')
        uniques=$(grep "^>" {input.derep} | awk -F '=' '{{s+=$2}}END{{print s}}')
        centroids=$(grep -c "^>" {input.centroids})
        nonsinglet=$(grep -c "^>" {input.nonsinglet})
        nonsinglet_read=$(grep "^>" {input.nonsinglet} | awk -F '=' '{{s+=$2}}END{{print s}}')
        non_chimera_denovo=$(grep -c "^>" {input.non_chimera_denovo})
        non_chimera_db=$(grep -c "^>" {input.non_chimera_db})
        non_chimera_denovo_read=$(grep "^>" {input.non_chimera_denovo} | awk -F '=' '{{s+=$2}}END{{print s}}')
        non_chimera_db_read=$(grep "^>" {input.non_chimera_db} | awk -F '=' '{{s+=$2}}END{{print s}}')
        
        # Calculating fractions
        nonsinglet_perc=$(echo "scale=2;(100* $nonsinglet / $centroids)" | bc)
        nonsinglet_perc_read=$(echo "scale=2;(100* $nonsinglet_read / $all)" | bc)
        chim_denovo=$(($nonsinglet - $non_chimera_denovo))
        chim_denovo_perc=$(echo "scale=2;(100* $chim_denovo / $nonsinglet)" | bc)
        chim_denovo_read=$(($nonsinglet_read - $non_chimera_denovo_read))
        chim_denovo_perc_read=$(echo "scale=2;(100* $chim_denovo_read / $nonsinglet_read)" | bc)
        chim_db=$(($non_chimera_denovo - $non_chimera_db))
        chim_db_perc=$(echo "scale=2;(100* $chim_db / $nonsinglet)" | bc)
        chim_db_read=$(($non_chimera_denovo_read - $non_chimera_db_read))
        chim_db_perc_read=$(echo "scale=2;(100* $chim_db_read / $nonsinglet_read)" | bc)
        non_chimera_perc=$(echo "scale=2;(100* $non_chimera_db_read / $all)" | bc)
        
        # Writting report
        echo "Number of samples\tNumber of Reads (total)\tNumber of reads (unique)\tCentroid number\tNon-singleton centroids\tNon-singleton centroids [%]\tNon-singleton centroids [read number]\tNon-singleton centroids [% of reads]\tChimera (de novo)\tChimera (de novo) [%]\tChimera (database)\tChimera (database) [%]\tChimera (de novo) [reads]\tChimera (de novo) [% of reads]\tChimera (database) [reads]\tChimera (database) [% of reads]\tOTU number\tReads in OTU\tReads in OTU [%]" > {output}
        echo "$n_samples\t$all\t$uniques\t$centroids\t$nonsinglet\t$nonsinglet_perc\t$nonsinglet_read\t$nonsinglet_perc_read\t$chim_denovo\t$chim_denovo_perc\t$chim_db\t$chim_db_perc\t$chim_denovo_read\t$chim_denovo_perc_read\t$chim_db_read\t$chim_db_perc_read\t$non_chimera_db\t$non_chimera_db_read\t$non_chimera_perc" >> {output}
        """

# Reads mapping rules----------------------------

rule map_sample:
    input:
        fasta = "{sample}/{sample}.derep.fasta",
        db = "VSEARCH/otus.fasta"
    output:
        otu = "{sample}/{sample}_otutab.tsv",
    params:
        clusterID = config["cluster"]["cluster_identity"]
    threads: config["threads"]
    conda: "envs/vsearch.yaml"
    message: "Mapping {wildcards.sample} to OTUs"
    log:
        "logs/{sample}_map_reads.log"
    shell:
        """
        vsearch --usearch_global {input.fasta} --threads {threads} --db {input.db} --id {params.clusterID}\
        --strand plus --sizein --sizeout --fasta_width 0 --qmask none --dbmask none --otutabout {output.otu} | tee {log} 2>&1     

        tail -n +2 {output.otu} | sort -k 2,2nr -o {output.otu} 
        """

rule mapping_stats:
    input: 
        fasta = "{sample}/{sample}.derep.fasta",
        otu = "{sample}/{sample}_otutab.tsv"
    output:
        "{sample}/{sample}_mapping_report.tsv"
    message: "Collecting mapping summary for {wildcards.sample}"
    shell:
        """
        # Collecting counts
        nreads=$(grep "^>" {input.fasta} | awk -F '=' '{{s+=$2}}END{{print s}}')
        nmapped=$(awk '{{s+=$2}}END{{print s}}' {input.otu})
        notu=$(grep -c "OTU_" {input.otu})
        max=$(head -n 1 {input.otu} | cut -f 2)
        min=$(tail -n 1 {input.otu} | cut -f 2)
        
        # Calculating fractions
        map_perc=$(echo "scale=2;(100* $nmapped / $nreads)" | bc)
        
        #Writting to file
        echo "Sample\tRead number\tReads mapped\tReads mapped [%]\tOTU number\tMax count\tMin count" > {output}
        echo "{wildcards.sample}\t$nreads\t$nmapped\t$map_perc\t$notu\t$max\t$min" >> {output}
        """

rule collect_mapping_stats:
    input:
        expand("{sample}/{sample}_mapping_report.tsv", sample = samples.index)
    output:
        "reports/mapping_stats.tsv"
    message: "Collecting mapping stats"
    shell:
        """
        cat {input[0]} | head -n 1 > {output}
        for i in {input}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        """
        
# OTU BLAST rules----------------------------

rule blast_otus:
    input: 
        "VSEARCH/otus.fasta"
    output:
        "blast/blast_search.tsv"
    params:
        blast_DB = config["blast"]["blast_DB"],
        taxdb = config["blast"]["taxdb"],
        e_value = config["blast"]["e_value"],
        perc_identity = config["blast"]["perc_identity"],
        qcov = config["blast"]["qcov"] 
    threads: config["cores"]
    message: "BLASTing OTUs against local database"
    conda: "envs/blast.yaml"
    log:
        "logs/blast.log"
    shell:
        """
        export BLASTDB={params.taxdb}
        
        blastn -db {params.blast_DB} -query {input} -out {output} -task 'megablast' -evalue {params.e_value} -perc_identity {params.perc_identity} -qcov_hsp_perc {params.qcov} \
        -outfmt '6 qseqid sseqid evalue pident bitscore sacc staxids sscinames scomnames stitle' -num_threads {threads} |\
        tee {log} 2>&1
        """

rule filter_blast:
    input:
        "blast/blast_search.tsv"
    output:
        "blast/blast_filtered.tsv"
    params:
        bit_diff= config["blast"]["bit_score_diff"]
    message: "Filtering BLAST results"
    shell:
        """
        OTUs=$(cat {input} | cut -d";" -f1 | sort -u)
        for otu in $OTUs
        do
            max=$(grep -E "^${{otu}};" {input} | cut -f5 | sort -rn | head -n1)
            for hit in $(grep "^${{otu}};" {input} | tr '\t' '#' | tr ' ' '@')
            do
                val=$(echo $hit | cut -d'#' -f5)
                if [ $[$max - val] -le {params.bit_diff} ]
                then
                    echo $hit | tr '@' ' ' | tr '#' '\t' | tr ';' '\t' | cut -d'\t' --complement -f2  >> {output}
                fi
            done
        done
        """

# Taxonomy determination rules----------------------------

rule blast2lca:
    input:
        "blast/blast_filtered.tsv"
    output:
        "blast/consensus_table.tsv" 
    params:
        names = config["taxonomy"]["names_dmp"],
        nodes = config["taxonomy"]["nodes_dmp"]
    message: "Lowest common ancestor determination"
    script:
        "scripts/blast_to_lca.py"
        
rule blast_stats:
    input:
        otus = "VSEARCH/otus.fasta",
        blast = "blast/blast_search.tsv",
        filtered = "blast/blast_filtered.tsv",
        lca = "blast/consensus_table.tsv" 
    output:
        "reports/blast_stats.tsv"
    params:
        bit_diff= config["blast"]["bit_score_diff"]
    message: "Collecting BLAST stats"
    shell:
        """      
        # Get list of all OTUs
        OTUs=$(grep "^>" {input.otus} | cut -d";" -f1 | tr -d '>' | sort -u)
        
        for otu in $OTUs
        do
            bhits=$(grep -c -E "^${{otu}};" {input.blast} || true)
            if [ $bhits -eq 0 ]
            then
                # When there is no blast hit
                echo "$otu\t0\t0\t0\t0\t0\t-\t-" >> {output}
            else
                # Otherwise collect and print stats to file
                bit_best=$(grep -E "^${{otu}};" {input.blast} | cut -f5 | sort -rn | head -n1)
                bit_low=$(grep -E "^${{otu}};" {input.blast} | cut -f5 | sort -n | head -n1)
                bit_thr=$(($bit_best-{params.bit_diff}))
                shits=$(grep -c -E "^${{otu}}\>" {input.filtered})
                cons=$(grep -E "^${{otu}}\>" {input.lca} | cut -d'\t' -f2)
                rank=$(grep -E "^${{otu}}\>" {input.lca} | cut -d'\t' -f3)
                
                echo "$otu\t$bhits\t$bit_best\t$bit_low\t$bit_thr\t$shits\t$cons\t$rank" >> {output}
            fi
        done
        
        # Sort by number of blast hits and add header (just to get hits on top)
        sort -k2,2nr -o {output} {output}
        sed -i '1 i\Query\tBlast hits\tBest bit-score\tLowest bit-score\tBit-score threshold\tSaved Blast hits\tConsensus\tRank' {output}
        """

rule otutab2lca:
    input:
        otu = "{sample}/{sample}_otutab.tsv",
        lca = "reports/blast_stats.tsv"
    output:
        "{sample}/{sample}_composition.tsv"
    message:
        "Determining the composition of {wildcards.sample}"
    shell:
        """
        echo "Query\tsize\tConsensus\tRank" > {output}
        
        while IFS= read -r line
        do
            otu=$(echo $line | cut -d' ' -f1)
            size=$(echo $line | cut -d' ' -f2)
            cons=$(grep -E "^${{otu}}\>" {input.lca} | cut -d'\t' -f7)
            rank=$(grep -E "^${{otu}}\>" {input.lca} | cut -d'\t' -f8)
            echo "$otu\t$size\t$cons\t$rank" >> {output}
        done < {input.otu} 
        """
        
rule tax_stats:
    input:
        "{sample}/{sample}_composition.tsv" 
    output:
        "{sample}/{sample}_taxonomy_stats.tsv"
    message: "Collecting taxonomy stats for {wildcards.sample}"
    shell:
        """
        echo "Sample\tNo Blast hit\tSpecy consensus\tGenus consensus\tFamily consensus\tHigher rank consensus" > {output}
        
        nohits=$(grep -c "-" {input} || true)
        spec=$(grep -c "species" {input} || true)
        gen=$(grep -c "genus" {input} || true)
        fam=$(grep -c "family" {input} || true)
        other=$(( $(grep -c "OTU_" {input} || true) - $nohits - $spec - $gen - $fam ))
        
        echo "{wildcards.sample}\t$nohits\t$spec\t$gen\t$fam\t$other" >> {output}
        """
        
rule collect_tax_stats:
    input:
        samples = expand("{sample}/{sample}_taxonomy_stats.tsv", sample = samples.index),
        all = "reports/blast_stats.tsv"
    output:
        "reports/taxonomy_stats.tsv"
    message: "Collecting blast statistics"
    shell:
        """              
        # Summary
        nohits=$(grep -c "-" <(tail -n +2 {input.all}) || true)
        spec=$(grep -c "species" <(tail -n +2 {input.all}) || true)
        gen=$(grep -c "genus" <(tail -n +2 {input.all}) || true)
        fam=$(grep -c "family" <(tail -n +2 {input.all}) || true)
        other=$(( $(grep -c "OTU_" <(tail -n +2 {input.all}) || true) - $nohits - $spec - $gen - $fam ))
        
        echo "All\t$nohits\t$spec\t$gen\t$fam\t$other" >> {output}
        
        # Per sample
        for i in {input.samples}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        
        # Insert Header 
        sed -i "1 i\Sample\tNo Blast hit\tSpecy consensus\tGenus consensus\tFamily consensus\tHigher rank consensus" {output}
        """

rule summarize_results:
    input:
        compo = "{sample}/{sample}_composition.tsv"
    output:
        report = "{sample}/{sample}_result_summary.tsv"
    message:
        "Summarizing results for {wildcards.sample}"
    run:
        df = pd.read_csv(input.compo, sep="\t", header=0)
        groups = df.groupby(['Consensus', 'Rank'])['size'].sum().sort_values(ascending=False).to_frame().reset_index()
        groups['perc']= round(groups['size']/groups['size'].sum() *100, 2)
        groups.insert(0, 'Sample', wildcards.sample)
        groups.rename(columns={"size":"Number of reads", "perc":"Percent of total"}, index={"-": "No match"}, inplace = True)
        groups.to_csv(output.report, sep="\t", index = False)
        
rule collect_results:
    input:
        expand("{sample}/{sample}_result_summary.tsv", sample = samples.index)
    output:
        "reports/result_summary.tsv"
    message: "Collecting results"
    shell:
        """
        cat {input[0]} | head -n 1 > {output}
        for i in {input}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        """

# Report rules----------------------------

rule summary_report:
    input:
        fastp = "trimmed/reports/{sample}.tsv",
        filter = "{sample}/{sample}_qc_filtering_report.tsv",
        map = "{sample}/{sample}_mapping_report.tsv",
        tax = "{sample}/{sample}_taxonomy_stats.tsv"
    output:
        "{sample}/{sample}_summary.tsv"
    message: "Summarizing statistics for {wildcards.sample}"
    shell:
        """
        echo "Sample\tQ30 rate\tFiltered reads\tFiltered reads [%]\tMapped reads [%]\tOTU number\tSpecy consensus\tGenus consensus\tHigher rank\tNo consensus" > {output}
        
        Q30=$(tail -n +2 {input.fastp} | cut -d'\t' -f7)
        fil_reads=$(tail -n +2 {input.filter} | cut -d'\t' -f6)
        fil_perc=$(tail -n +2 {input.filter} | cut -d'\t' -f10) 
        mapped=$(tail -n +2 {input.map} | cut -d'\t' -f4)
        otu=$(tail -n +2 {input.map} | cut -d'\t' -f5)
        spec=$(tail -n +2 {input.tax} | cut -d'\t' -f3)
        gen=$(tail -n +2 {input.tax} | cut -d'\t' -f4)
        high=$(tail -n +2 {input.tax} | cut -d'\t' -f5)
        noc=$(tail -n +2 {input.tax} | cut -d'\t' -f2)
        
        echo "{wildcards.sample}\t$Q30\t$fil_reads\t$fil_perc\t$mapped\t$otu\t$spec\t$gen\t$high\t$noc" >> {output}
        """
        
rule collect_summaries:        
    input:
        expand("{sample}/{sample}_summary.tsv", sample= samples.index)
    output:
        "reports/summary.tsv"
    message: "Collecting summary reports"
    shell:
        """
        cat {input[0]} | head -n 1 > {output}
        for i in {input}; do 
            cat ${{i}} | tail -n +2 >> {output}
        done
        """

rule report_all:
    input:
        summary = "reports/summary.tsv",
        fastp = "reports/fastp_stats.tsv",
        qc_filtering = "reports/qc_filtering_stats.tsv",
        clustering = "reports/clustering_stats.tsv",
        mapping = "reports/mapping_stats.tsv",
        blast = "reports/blast_stats.tsv",
        taxonomy = "reports/taxonomy_stats.tsv",
        result = "reports/result_summary.tsv",
        db = "reports/db_versions.tsv",
        soft = "reports/software_versions.tsv"
    params:
        workdir = config["workdir"]
    output:
        "reports/summary.html"
    conda:
        "envs/rmarkdown.yaml"
    log:
        "logs/rmarkdown.log"
    message: "Generating html report"
    script:
        "scripts/write_report.Rmd"
          
rule software_versions:
    output:
        "reports/software_versions.tsv"
    message: "Collecting software versions"
    shell:
        """
        echo "Software\tVersion" > {output}
        paste <(echo "fastp") <(grep fastp= {workflow.basedir}/envs/fastp.yaml | cut -d "=" -f2) >> {output}
        paste <(echo "blast") <(grep blast= {workflow.basedir}/envs/blast.yaml | cut -d "=" -f2) >> {output}
        paste <(echo "vsearch") <(grep vsearch= {workflow.basedir}/envs/vsearch.yaml | cut -d "=" -f2) >> {output}
        """

rule database_version:
    output:
        "reports/db_versions.tsv"
    message: "Collecting databases versions"
    params:
        chimera = config["cluster"]["chimera_DB"],
        blast = config["blast"]["blast_DB"],
        taxdb = config["blast"]["taxdb"],
        taxdump = config["taxonomy"]["nodes_dmp"]
    shell:
        """
        echo "Database\tLast modified\tFull path" > {output}      
        paste <(echo "Chimera") <(date +%F -r {params.chimera}) <(echo {params.chimera}) >> {output}
        paste <(echo "BLAST") <(date +%F -r {params.blast}) <(echo {params.blast}) >> {output}
        paste <(echo "taxdb") <(date +%F -r {params.taxdb}/taxdb.bti) <(echo {params.chimera}/taxdb[.bti/.btd]) >> {output}
        paste <(echo "taxdump") <(date +%F -r {params.taxdump}) <(echo $(dirname {params.taxdump})/[names.dmp/nodes.dmp]) >> {output}
        """
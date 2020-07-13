#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from taxidTools import Taxdump
import pandas as pd

want_taxonomy = ['species', 'genus', 'family', 'order', 'class', 'phylum', 'kingdom']	

def get_lineage(taxid, txd):
	if taxid == "-":
		return ["Unassigned"]
	else:
		return txd.getLineageAsList(str(taxid), asNames=True)[::-1] # inverting list to have the lineage descending for Krona

def main(input, output, rankedlineage_dmp, nodes_dmp):
	txd = Taxdump(rankedlineage_dmp, nodes_dmp, want_taxonomy)
	df = pd.read_csv(input, sep='\t', header=0)
	with open(output, "w") as out:
		for index, row in df.iterrows():
			out.write("\t".join([str(row["Count"])] + get_lineage(row['Taxid'], txd)) + "\n")
	
if __name__ == '__main__':	
	main(snakemake.input[0], snakemake.output[0], snakemake.params["lineage"], snakemake.params["nodes"])
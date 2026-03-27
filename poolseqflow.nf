#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { VerifyEnvironment }   from './scripts/0_verify_environment.nf'
include { BuildDictionaries }   from './scripts/1_build_dictionaries.nf'
include { TrimQcClip }          from './scripts/2_trim_reads.nf'
include { AlignReads }          from './scripts/3_align.nf'
include { SortCleanBams }       from './scripts/4_clean.nf'
include { GenerateReports }     from './scripts/5_reports.nf'
include { VariantCalling }      from './scripts/6_variant_call.nf'
include { VCF2Frequencies }     from './scripts/7_vcf2freq.nf'
include { AnnotateVCF }         from './scripts/8_annotate_variants.nf'

workflow {
    VerifyEnvironment()
    BuildDictionaries(VerifyEnvironment.out)
    
    TrimQcClip(VerifyEnvironment.out)
    AlignReads(TrimQcClip.out, BuildDictionaries.out.bwa_index)  
    SortCleanBams(AlignReads.out.aligned_bam)
    
    GenerateReports(SortCleanBams.out.ready_bam,SortCleanBams.out.ready_bai)
    VariantCalling(SortCleanBams.out.ready_bam, BuildDictionaries.out.fai_index)
    VCF2Frequencies(VariantCalling.out.vcf)
    if (params.annotate) {
        AnnotateVCF(VariantCalling.out.vcf, BuildDictionaries.out.snpeff_db_verify)
    }
}
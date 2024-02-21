params.bam = null
params.genome = null
params.cytobands = true
params.results = "results"

log.info """\
    W G S  C O V E R A G E
    ======================
        bam: ${params.bam}
     genome: ${params.genome}
  cytobands: ${params.cytobands}
    results: ${params.results}
    regions: ${params.regions}
    """

process mosdepth {
    container 'quay.io/biocontainers/mosdepth:0.3.6--hd299d5a_0'
    publishDir "${params.results}/${sample}"

    input:
    tuple val(sample), path(bam), path(bai)

    output:
    path '*.per-base.d4', emit: 'per_base_d4'
    path '*.mosdepth.global.dist.txt', emit: 'global_dist'
    path '*.mosdepth.summary.txt', emit: 'summary'

    script:
    """
    mosdepth -t ${task.cpus} --d4 ${sample} $bam
    """
}

process samtools_index {
    container 'quay.io/biocontainers/samtools:1.19.1--h50ea8bc_0'

    input:
    path bam

    output:
    path "*.bai", emit: "bai"

    script:
    """
    samtools index $bam
    """
}

process plot_coverage {
    conda "${projectDir}/environments/plot_coverage.yaml"
    publishDir "${params.results}/${sample}/plots"

    input:
    val sample
    path coverage
    path cytobands
    path regions

    output:
    path '*.png', emit: plots

    script:
    cytoband_arg = ""
    if (params.cytobands) {
        cytoband_arg = "--cytobands $cytobands"
    }

    region_arg = ""
    if (regions.name != "NO_FILE") {
        region_arg = "--regions $regions"
    }

    """
    plot_coverage.py $region_arg $cytoband_arg -o ${sample} $coverage
    """
}

process split_bed {
    container 'quay.io/biocontainers/csvtk:0.29.0--h9ee0642_0'

    input:
    path bed

    output:
    path "*.${extension}", emit: split_bed

    script:
    extension = bed.getExtension()
    """
    csvtk split --no-header-row --tabs -f 4 $bed
    """
}

process guess_genome {
    container "quay.io/biocontainers/pysam:0.22.0--py39hcada746_0"

    input:
    tuple val(sample), path(bam), path(bai)

    output:
    stdout

    script:
    """
    guess_genome.py $bam
    """
}

def is_newer(a, b) {
    return file(a).lastModified() > file(b).lastModified()
}

workflow {
    if (params.bam == null) {
        error("No bam file provided")
    }

    bam = file(params.bam, checkIfExists: true)
    bai = file("${params.bam}.bai")
    sample = bam.getBaseName().split("_").first()

    if (!bai.exists() || !is_newer(bai, bam)) {
        bai_ch = samtools_index(Channel.fromPath(bam))
    } else {
        bai_ch = Channel.fromPath(bai)
    }

    bam_ch = Channel.of([sample, bam]).combine(bai_ch)

    if (!params.genome) {
        genome_ch = guess_genome(bam_ch)
        genome_ch.view { log.info "guessing genome build is $it" }
    } else {
        genome_ch = Channel.value(params.genome)
    }

    cytoband_ch = genome_ch.map { file("${projectDir}/data/cytoBand.${it}.txt") }

    regions_ch = Channel.fromPath(file("${projectDir}/assets/NO_FILE"))
    if (params.regions) {
        regions_ch = Channel.fromPath(file(params.regions))
    }

    coverage = mosdepth(bam_ch)
    plot_coverage(sample, coverage.per_base_d4, cytoband_ch, regions_ch)
}

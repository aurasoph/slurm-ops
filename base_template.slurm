--export=name=value to sbatch, then ${name} 
#!/bin/bash
#SBATCH ...
#SBATCH --chdir=/gscratch/sewoong/jhayase/hyak-hacks/
#SBATCH --output=/gscratch/sewoong/jhayase/hyak-hacks/slurm-%j.out
#SBATCH --error=/gscratch/sewoong/jhayase/hyak-hacks/slurm-%j.out
source /gscratch/sewoong/jhayase/bin/miniconda3/etc/profile.d/conda.sh
conda activate hyak-hacks-env
python train.py

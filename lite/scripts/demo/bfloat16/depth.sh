#!/bin/bash

cd ../../.. || exit
SAPIENS_CHECKPOINT_ROOT=/home/${USER}/sapiens_lite_host

# MODE='torchscript' ## original. no optimizations (slow). full precision inference.
MODE='bfloat16' ## A100 gpus. faster inference at bfloat16

SAPIENS_CHECKPOINT_ROOT=$SAPIENS_CHECKPOINT_ROOT/$MODE

#----------------------------set your input and output directories----------------------------------------------
INPUT='../pose/demo/data/itw_videos/reel1'
SEG_DIR="/home/${USER}/Desktop/sapiens/seg/Outputs/vis/itw_videos/reel1_seg/sapiens_1b"
OUTPUT="/home/${USER}/Desktop/sapiens/seg/Outputs/vis/itw_videos/reel1_depth"

#--------------------------MODEL CARD---------------
# MODEL_NAME='sapiens_0.3b'; CHECKPOINT=$SAPIENS_CHECKPOINT_ROOT/depth/checkpoints/sapiens_0.3b/sapiens_0.3b_render_people_epoch_100_$MODE.pt2
# MODEL_NAME='sapiens_0.6b'; CHECKPOINT=$SAPIENS_CHECKPOINT_ROOT/depth/checkpoints/sapiens_0.6b/sapiens_0.6b_render_people_epoch_70_$MODE.pt2
# MODEL_NAME='sapiens_1b'; CHECKPOINT=$SAPIENS_CHECKPOINT_ROOT/depth/checkpoints/sapiens_1b/sapiens_1b_render_people_epoch_88_$MODE.pt2
MODEL_NAME='sapiens_2b'; CHECKPOINT=$SAPIENS_CHECKPOINT_ROOT/depth/checkpoints/sapiens_2b/sapiens_2b_render_people_epoch_25_$MODE.pt2

OUTPUT=$OUTPUT/$MODEL_NAME

##-------------------------------------inference-------------------------------------
RUN_FILE='demo/vis_depth.py'

# JOBS_PER_GPU=1; TOTAL_GPUS=8; VALID_GPU_IDS=(0 1 2 3 4 5 6 7)
JOBS_PER_GPU=1; TOTAL_GPUS=1; VALID_GPU_IDS=(0)

BATCH_SIZE=18

# Find all images and sort them, then write to a temporary text file
IMAGE_LIST="${INPUT}/image_list.txt"
find "${INPUT}" -type f \( -iname \*.jpg -o -iname \*.png \) | sort > "${IMAGE_LIST}"

# Check if image list was created successfully
if [ ! -s "${IMAGE_LIST}" ]; then
  echo "No images found. Check your input directory and permissions."
  exit 1
fi

# Count images and calculate the number of images per text file
NUM_IMAGES=$(wc -l < "${IMAGE_LIST}")
if ((TOTAL_GPUS > NUM_IMAGES / BATCH_SIZE)); then
  TOTAL_JOBS=$(( (NUM_IMAGES + BATCH_SIZE - 1) / BATCH_SIZE))
  IMAGES_PER_FILE=$((BATCH_SIZE))
  EXTRA_IMAGES=$((NUM_IMAGES - ((TOTAL_JOBS - 1) * BATCH_SIZE)  ))
else
  TOTAL_JOBS=$((JOBS_PER_GPU * TOTAL_GPUS))
  IMAGES_PER_FILE=$((NUM_IMAGES / TOTAL_JOBS))
  EXTRA_IMAGES=$((NUM_IMAGES % TOTAL_JOBS))
fi

export TF_CPP_MIN_LOG_LEVEL=2
echo "Distributing ${NUM_IMAGES} image paths into ${TOTAL_JOBS} jobs."

# Divide image paths into text files for each job
for ((i=0; i<TOTAL_JOBS; i++)); do
  TEXT_FILE="${INPUT}/image_paths_$((i+1)).txt"
  if [ $i -eq $((TOTAL_JOBS - 1)) ]; then
    # For the last text file, write all remaining image paths
    tail -n +$((IMAGES_PER_FILE * i + 1)) "${IMAGE_LIST}" > "${TEXT_FILE}"
  else
    # Write the exact number of image paths per text file
    head -n $((IMAGES_PER_FILE * (i + 1))) "${IMAGE_LIST}" | tail -n ${IMAGES_PER_FILE} > "${TEXT_FILE}"
  fi
done

# Run the process on the GPUs, allowing multiple jobs per GPU
for ((i=0; i<TOTAL_JOBS; i++)); do
  GPU_ID=$((i % TOTAL_GPUS))
  CUDA_VISIBLE_DEVICES=${VALID_GPU_IDS[GPU_ID]} python ${RUN_FILE} \
    ${CHECKPOINT} \
    --input "${INPUT}/image_paths_$((i+1)).txt" \
    --seg_dir ${SEG_DIR} \
    --batch-size="${BATCH_SIZE}" \
    --output-root="${OUTPUT}" ## add & to process in background
  # Allow a short delay between starting each job to reduce system load spikes
  sleep 1
done

# Wait for all background processes to finish
wait

# Remove the image list and temporary text files
rm "${IMAGE_LIST}"
for ((i=0; i<TOTAL_JOBS; i++)); do
  rm "${INPUT}/image_paths_$((i+1)).txt"
done

# Go back to the original script's directory
cd -

echo "Processing complete."
echo "Results saved to $OUTPUT"

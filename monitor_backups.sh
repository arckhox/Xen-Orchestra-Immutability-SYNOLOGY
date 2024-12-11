#!/bin/bash

# Directory where backups are stored (customize if necessary)
BACKUP_DIR="/volume1/XCP06"
IMMU_DURATION=1209600  # 14 days in seconds
BACKUP_STATE_FILE="/volume1/scripts/backup_state.json"

# Log file for debugging
LOG_FILE="/volume1/scripts/monitor_backups.log"
echo "$(date) - Starting monitor_backups.sh" >> "$LOG_FILE"

# Check if the backup_state.json file exists, if not create it
if [ ! -f "$BACKUP_STATE_FILE" ]; then
  echo "{}" > "$BACKUP_STATE_FILE"
fi

# Function to save backup state
save_backup_state() {
  BACKUP_DIR="$1"
  BACKUP_TIMESTAMP="$2"
  jq --arg dir "$BACKUP_DIR" --arg timestamp "$BACKUP_TIMESTAMP" \
    '. + {($dir): $timestamp}' "$BACKUP_STATE_FILE" > tmp.json && mv tmp.json "$BACKUP_STATE_FILE"
  echo "$(date) - Saved state for $BACKUP_DIR with timestamp $BACKUP_TIMESTAMP" >> "$LOG_FILE"
}

# Function to read backup state
get_backup_state() {
  BACKUP_DIR="$1"
  jq -r --arg dir "$BACKUP_DIR" '.[$dir]' "$BACKUP_STATE_FILE"
}

# Function to check if a directory is a Btrfs subvolume
is_subvolume() {
  DIR="$1"
  sudo btrfs subvolume show "$DIR" &>/dev/null
  if [ $? -eq 0 ]; then
    return 0  # Directory is a subvolume
  else
    return 1  # Directory is not a subvolume
  fi
}

# Function to move files to a temporary folder, create a subvolume, and make the subvolume immutable
move_files_to_subvolume() {
  DIR="$1"
  TEMP_DIR="${DIR}.temp"

  # Create temp directory to store files temporarily
  sudo mkdir -p "$TEMP_DIR"
  echo "$(date) - Created temp directory $TEMP_DIR to store files temporarily" >> "$LOG_FILE"

  # Move all files from the original directory to the temp directory
  sudo mv "$DIR" "$TEMP_DIR"
  echo "$(date) - Moved files from $DIR to temp directory $TEMP_DIR" >> "$LOG_FILE"

  # Create the subvolume
  sudo btrfs subvolume create "$DIR"
  echo "$(date) - Created subvolume $DIR" >> "$LOG_FILE"

  # Move files back into the original directory (now a subvolume)
  sudo mv "$TEMP_DIR"/* "$DIR"
  sudo rmdir "$TEMP_DIR"  # Remove the temp directory
  echo "$(date) - Moved files back into subvolume $DIR and removed temp directory" >> "$LOG_FILE"

  # Make the subvolume immutable
  make_immutable "$DIR"
}

# Function to make a directory or subvolume immutable
make_immutable() {
  DIR="$1"
  if [[ "$DIR" == *@eaDir* || "$DIR" == *.snapshots* ]]; then
    echo "$(date) - Skipping special directory $DIR" >> "$LOG_FILE"
    return
  fi

  # Exclude cache.json.gz while setting the directory immutable
  if is_subvolume "$DIR"; then
    echo "$(date) - Making subvolume $DIR immutable (excluding cache.json.gz)" >> "$LOG_FILE"
    find "$DIR" -type f ! -name "cache.json.gz" -exec sudo btrfs property set {} ro true \;
  else
    echo "$(date) - Making directory $DIR immutable and converting to subvolume (excluding cache.json.gz)" >> "$LOG_FILE"
    sudo btrfs subvolume create "$DIR"
    find "$DIR" -type f ! -name "cache.json.gz" -exec sudo btrfs property set {} ro true \;
  fi
}


# Function to lift immutability on a subvolume
lift_immutability() {
  DIR="$1"
  if is_subvolume "$DIR"; then
    echo "$(date) - Lifting immutability for subvolume $DIR" >> "$LOG_FILE"
    sudo btrfs property set "$DIR" ro false
  else
    echo "$(date) - $DIR is not a subvolume; nothing to do" >> "$LOG_FILE"
  fi
}

# Loop to monitor new directories
while true; do
  CURRENT_TIME=$(date +%s)  # Update the current time on each iteration

  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | while read NEW_BACKUP; do
    # Get the timestamp of when the backup was created
    BACKUP_STATE=$(get_backup_state "$NEW_BACKUP")

    # Skip already processed directories
    if [ "$BACKUP_STATE" == "null" ]; then
      # Check if the backup directory contains a .vhd file
      if find "$NEW_BACKUP" -type f -name "*.vhd" | grep -q .; then
        echo "$(date) - .vhd file found in $NEW_BACKUP" >> "$LOG_FILE"

        # If the directory is not already in the state file, process it
        save_backup_state "$NEW_BACKUP" "$CURRENT_TIME"
        move_files_to_subvolume "$NEW_BACKUP"  # Move files and create subvolume
      fi
    else
      BACKUP_STATE_INT=$((BACKUP_STATE))  # Convert to integer for comparison
      if [ $(($CURRENT_TIME - $BACKUP_STATE_INT)) -ge $IMMU_DURATION ]; then
        lift_immutability "$NEW_BACKUP"  # Lift immutability
        jq --arg dir "$NEW_BACKUP" 'del(.[$dir])' "$BACKUP_STATE_FILE" > tmp.json && mv tmp.json "$BACKUP_STATE_FILE"
        echo "$(date) - Lifted immutability for $NEW_BACKUP" >> "$LOG_FILE"
      else
        echo "$(date) - $NEW_BACKUP still within immutability period" >> "$LOG_FILE"
      fi
    fi
  done

  # Sleep for a minute before checking again
  sleep 60
done

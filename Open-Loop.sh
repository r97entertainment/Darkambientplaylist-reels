#!/bin/bash
set -e

# --- 1. CONFIGURATION ---
TMP=$(mktemp -d)
INPUT_DIR="./reels"
AUDIO_DIR="./audio"
QUOTES_FILE="./assets/Open-Loop-quotes.txt"
FONT="./assets/Inter-Black.ttf"
LOGO_PATH="./assets/spotify.png"
OUTPUT_DIR="./output"

mkdir -p "$OUTPUT_DIR"

# --- 2. ASSET PICKING (5 Clips x 3 Seconds = 15s Total) ---
FILES=($(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) | shuf -n 5))
AUDIO_FILE=$(find "$AUDIO_DIR" -maxdepth 1 -type f -iname "*.mp3" | shuf -n 1)

if [ ${#FILES[@]} -eq 0 ]; then echo "❌ No videos found"; exit 1; fi

# --- 3. MERGE CLIPS ---
echo "🎬 Step 1: Processing Clips (3-second cuts)..."
i=1
for f in "${FILES[@]}"; do
  ffmpeg -i "$f" -t 3 -vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black,fps=30" \
    -c:v libx264 -preset superfast -pix_fmt yuv420p -an "$TMP/clip_$i.mp4" -y -loglevel error
  echo "file '$TMP/clip_$i.mp4'" >> "$TMP/list.txt"
  i=$((i+1))
done

MERGED_RAW="$TMP/merged_raw.mp4"
ffmpeg -f concat -safe 0 -i "$TMP/list.txt" -c copy "$MERGED_RAW" -y -loglevel error
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MERGED_RAW")

# --- 4. PARSE QUOTE & TEXT PREP ---
echo "🎨 Step 2: Applying Split Text Logic (Duration: ${DUR}s)..."
TOTAL=$(wc -l < "$QUOTES_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
line=$((RANDOM % TOTAL + 1))
raw=$(sed -n "${line}p" "$QUOTES_FILE" | perl -pe 's/[^[:ascii:]]//g; s/[\x00-\x1f\x7f]//g')

# Split by the pipe character
part1=$(echo "$raw" | awk -F'|' '{print $1}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
part2=$(echo "$raw" | awk -F'|' '{print $2}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

echo "$part1" | fold -s -w 45 > "$TMP/quote_part1.txt"
echo "$part2" | fold -s -w 45 > "$TMP/quote_part2.txt"

# --- 5. VISUAL TIMING & FILTERS ---
# Logo fades IN at 4.5s and OUT at 10.0s. Placed at the bottom: y=H-h-120
# Text 1 is permanent. Text 2 appears at 11.0s. Fontsize set to 40.
FILTER="[1:v]scale=180:-1,format=rgba,fade=t=in:st=4.5:d=0.5:alpha=1,fade=t=out:st=10.0:d=0.5:alpha=1[logo_p]; \
[0:v][logo_p]overlay=x=(W-w)/2:y=H-h-120:shortest=1[v_l]; \
[v_l]drawtext=fontfile='${FONT}':textfile='$TMP/quote_part1.txt':fontcolor=white:fontsize=40: \
shadowcolor=black:shadowx=3:shadowy=3:line_spacing=15:x=(w-text_w)/2:y=(h*0.12):expansion=none[v_t1]; \
[v_t1]drawtext=fontfile='${FONT}':textfile='$TMP/quote_part2.txt':fontcolor=white:fontsize=40: \
shadowcolor=black:shadowx=3:shadowy=3:line_spacing=15:x=(w-text_w)/2:y=(h*0.12)+60: \
enable='gte(t,11.0)':expansion=none[v_f]"

VISUAL_MASTER="$TMP/visual_master.mp4"

ffmpeg -i "$MERGED_RAW" -loop 1 -i "$LOGO_PATH" -filter_complex "$FILTER" \
  -map "[v_f]" -c:v libx264 -preset veryslow -crf 24 -tune stillimage -pix_fmt yuv420p -an "$VISUAL_MASTER" -y -loglevel warning

# --- 6. AUDIO & RENAMING ---
echo "🎵 Step 3: Adding Audio..."
FADE_VAL=$(echo "$DUR" | awk '{print ($1 > 2) ? $1 - 2 : 0}')

# Sanitize Part 1 for filename
safe_name=$(echo "$part1" | tr -cd '[:alnum:] ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-50)
url_filename="${safe_name// /_}.mp4"
out_file="$OUTPUT_DIR/$url_filename"

# Final merge
ffmpeg -i "$VISUAL_MASTER" -i "$AUDIO_FILE" \
  -filter_complex "[1:a]afade=t=out:st=${FADE_VAL}:d=2[aud]" \
  -map 0:v -map "[aud]" -c:v copy -c:a aac -b:a 128k -shortest \
  -movflags +faststart "$out_file" -y -loglevel warning

# --- 7. GITHUB UPLOAD ---
if [ -f "$out_file" ]; then
    echo "-----------------------------------------------"
    echo "📤 UPLOADING TO PUBLIC REPO..."

    git config --global user.name "github-actions[bot]"
    git config --global user.email "github-actions[bot]@users.noreply.github.com"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    echo "🌿 Detected branch: $CURRENT_BRANCH"

    find "$OUTPUT_DIR" -type f ! -name "$url_filename" -delete
    
    git add .
    git add "$out_file"

    RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${CURRENT_BRANCH}/output/${url_filename}"

    if [ -n "$GITHUB_ACTIONS" ]; then
        echo "⚙️ Force pushing to $CURRENT_BRANCH..."
        git commit -m "Refresh Open Loop Reel: $safe_name" || git commit --amend --no-edit
        git push origin "$CURRENT_BRANCH" --force
    fi

    # --- 8. WEBHOOK CALL ---
    if [ -n "$WEBHOOK_URL" ]; then
        echo "📡 Sending Webhook..."
        PAYLOAD=$(cat <<EOF
{
  "fileUrl": "$RAW_URL",
  "fileName": "$safe_name"
}
EOF
)
        curl -L -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL"
        echo -e "\n✨ Process Complete."
    fi
    echo "-----------------------------------------------"
else
    echo "❌ Error: Final video file was not created."
    exit 1
fi

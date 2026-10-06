#!/usr/bin/env bash
source scripts/util.sh

# Script to extract bundle and component images from an IIB
# Optionally replaces registry URLs with quay.io equivalents

iib_url=$1
version=$2
use_quay="${3:-true}"  # Default to true for backward compatibility

# Print usage if parameters are missing
if [[ -z $1 || -z $2 ]]; then
  echo "Usage: ./iib_to_components.sh <iib_url> <version> [use_quay]"
  echo ""
  echo "Description:"
  echo "  This script extracts the bundle image from an IIB and then extracts"
  echo "  component images from the bundle. It can optionally replace"
  echo "  registry.redhat.io URLs with quay.io equivalents where possible."
  echo "  At the end, you will be prompted to pull all images if desired."
  echo ""
  echo "Arguments:"
  echo "  iib_url   - URL to the IIB image"
  echo "  version   - Version of the operator (e.g., 2.9.0, 2.10.0)"
  echo "  use_quay  - Replace URLs with quay.io alternatives (true|false, default: true)"
  echo ""
  echo "Examples:"
  echo "  # Use quay.io alternatives (default)"
  echo "  $0 registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5"
  echo "  $0 registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5 true"
  echo ""
  echo "  # Keep original URLs, no quay replacement"
  echo "  $0 registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5 false"
  echo ""
  echo "  # With quay IIB"
  echo "  $0 quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d 2.9.0"
  echo ""
  exit 0
fi

# Store original IIB URL
original_iib_url=$iib_url

echo ""
log_info "IIB to Components Extraction"
echo "=========================================="
log_info "Original IIB URL: $iib_url"
log_info "Version: $version"
log_info "Use quay.io alternatives: $use_quay"
echo ""

# Step 1: Extract bundle image from IIB
log_info "Step 1: Extracting bundle image from IIB..."
echo "------------------------------------------"

scripts/iib.sh "$iib_url" "$version"
bundle_img=$(r_output | jq '.BUNDLE_IMAGE' -r)

if [[ -z "$bundle_img" || "$bundle_img" == "null" ]]; then
  log_error "Failed to extract bundle image from IIB"
  exit 1
fi

log_success "Bundle image extracted: $bundle_img"
original_bundle_url=$bundle_img
echo ""

# Step 2: Try to replace bundle URL with quay equivalent
log_info "Step 2: Checking for quay.io alternative for bundle..."
echo "------------------------------------------------------"

if [[ "$use_quay" == "true" ]]; then
  if [[ "$bundle_img" == *"redhat.io"* ]]; then
    bundle_img_quay=$(scripts/replace_for_quay.sh "$bundle_img" "$version")

    if [[ "$bundle_img_quay" != "$bundle_img" ]]; then
      log_info "Quay.io alternative available"
      echo "  Original:  $bundle_img"
      echo "  Quay:      $bundle_img_quay"

      # Verify quay image exists
      log_info "  Verifying quay image exists..."
      if skopeo inspect --no-tags "docker://${bundle_img_quay}" &>/dev/null; then
        log_success "  Quay image verified, using quay.io URL"
        bundle_img=$bundle_img_quay
      else
        log_warning "  Quay image not accessible, using original URL"
        bundle_img=$original_bundle_url
      fi
    else
      log_info "Bundle already uses quay.io or no alternative available"
    fi
  else
    log_info "Bundle not from redhat.io registry, no replacement needed"
  fi
else
  log_info "Quay replacement disabled, using original bundle URL"
fi
echo ""

# Step 3: Extract component images from bundle
log_info "Step 3: Extracting component images from bundle..."
echo "---------------------------------------------------"

scripts/bundle.sh "$bundle_img"
components=$(r_output | jq '.' -r)

if [[ -z "$components" || "$components" == "null" ]]; then
  log_error "Failed to extract components from bundle"
  exit 1
fi

component_count=$(echo "$components" | jq 'keys | length')
log_success "Extracted $component_count component images"
echo ""

# Step 4: Try to replace component URLs with quay equivalents and display
log_info "Step 4: Processing component images..."
echo "---------------------------------------"

# Clear output file for final results
cl_output

# Prepare final JSON structure
final_output=$(
  cat <<EOF
{
  "iib_url": "$original_iib_url",
  "version": "$version",
  "use_quay": $use_quay,
  "bundle_url": "$original_bundle_url",
  "bundle_url_quay": "$bundle_img",
  "components": {}
}
EOF
)

echo ""
printf "%-40s %-20s %s\n" "COMPONENT" "SOURCE" "IMAGE URL"
printf "%-40s %-20s %s\n" "========================================" "====================" "==========================================="

# Statistics
quay_replaced=0
quay_unavailable=0
original_used=0

for cmp_name in $(echo "$components" | jq 'keys[]' -r); do
  cmp_url=$(echo "$components" | jq -r --arg name "$cmp_name" '.[$name]')
  original_cmp_url=$cmp_url
  source_registry="original"
  quay_available="false"

  # Identify current source
  if [[ "$cmp_url" == *"quay.io"* ]]; then
    source_registry="quay.io"
  fi

  # Try to replace with quay if enabled
  if [[ "$use_quay" == "true" ]]; then
    if [[ "$cmp_url" == *"redhat.io"* ]]; then
      cmp_url_quay=$(scripts/replace_for_quay.sh "$cmp_url" "$version")

      if [[ "$cmp_url_quay" != "$cmp_url" ]]; then
        # Verify quay image exists (silent check)
        if skopeo inspect --no-tags "docker://${cmp_url_quay}" &>/dev/null; then
          cmp_url=$cmp_url_quay
          source_registry="quay.io"
          quay_available="true"
        else
          quay_available="not-accessible"
        fi
      fi
    fi
  fi

  # Display component info
  printf "%-40s %-20s %s\n" "$cmp_name" "$source_registry" "$cmp_url"

  # Update statistics
  if [[ "$source_registry" == "quay.io" && "$original_cmp_url" != "$cmp_url" ]]; then
    quay_replaced=$((quay_replaced + 1))
  elif [[ "$quay_available" == "not-accessible" ]]; then
    quay_unavailable=$((quay_unavailable + 1))
    original_used=$((original_used + 1))
  elif [[ "$source_registry" != "quay.io" ]]; then
    original_used=$((original_used + 1))
  fi

  # Add to final output JSON
  final_output=$(echo "$final_output" | jq --arg name "$cmp_name" \
    --arg orig "$original_cmp_url" \
    --arg current "$cmp_url" \
    --arg source "$source_registry" \
    --arg quay_avail "$quay_available" \
    '.components[$name] = {"original": $orig, "current": $current, "source": $source, "quay_available": $quay_avail}')
done

echo ""
echo "=========================================="
log_info "Summary"
echo "=========================================="
echo "IIB URL:             $original_iib_url"
echo "Bundle URL:          $original_bundle_url"
if [[ "$bundle_img" != "$original_bundle_url" ]]; then
  echo "Bundle URL (quay):   $bundle_img"
fi
echo "Total Components:    $component_count"
if [[ "$use_quay" == "true" ]]; then
  log_success "Replaced with quay:  $quay_replaced"
  echo "Original URLs used:  $original_used"
  if [[ $quay_unavailable -gt 0 ]]; then
    log_warning "Quay unavailable:    $quay_unavailable"
  fi
else
  log_info "Quay replacement:    disabled"
fi
echo ""

# Write final JSON output to cmd_output file
w_output "$(echo "$final_output" | jq '.')"

log_success "### RESULT ###"
log_info "Detailed JSON output written to: cmd_output"
log_info "To view JSON output: cat cmd_output"
echo ""

# Ask user if they want to pull all component images
echo "=========================================="
log_info "Pull Images?"
echo "=========================================="
echo -n "Do you want to pull all component images (bundle + components)? [y/N]: "
read -r pull_response

if [[ "$pull_response" =~ ^[Yy]$ ]]; then
  echo ""
  log_info "Starting image pull process..."
  echo "=========================================="

  # Collect all images to pull (bundle + components)
  images_to_pull=()
  images_to_pull+=("$bundle_img")

  for cmp_name in $(echo "$components" | jq 'keys[]' -r); do
    cmp_url=$(echo "$final_output" | jq -r --arg name "$cmp_name" '.components[$name].current')
    images_to_pull+=("$cmp_url")
  done

  total_images=${#images_to_pull[@]}
  pulled_count=0
  failed_count=0
  failed_images=()

  log_info "Total images to pull: $total_images"
  echo ""

  for img_url in "${images_to_pull[@]}"; do
    pulled_count=$((pulled_count + 1))

    # Extract image name for display
    img_name=${img_url##*/}
    img_name=${img_name%%@*}
    img_name=${img_name%%:*}

    log_info "[$pulled_count/$total_images] Pulling: $img_name"
    echo "  Source: $img_url"

    # Use skopeo copy to pull image to local container storage
    if skopeo copy --quiet "docker://$img_url" "containers-storage:$img_url" 2>&1 | grep -v "^$" | sed 's/^/  /'; then
      log_success "  ✓ Successfully pulled: $img_name"
    else
      log_error "  ✗ Failed to pull: $img_name"
      failed_count=$((failed_count + 1))
      failed_images+=("$img_url")
    fi
    echo ""
  done

  echo "=========================================="
  log_info "Pull Summary"
  echo "=========================================="
  log_success "Successfully pulled: $((total_images - failed_count))/$total_images"

  if [[ $failed_count -gt 0 ]]; then
    log_error "Failed to pull: $failed_count/$total_images"
    echo ""
    log_warning "Failed images:"
    for failed_img in "${failed_images[@]}"; do
      echo "  - $failed_img"
    done
  fi
  echo ""
else
  log_info "Skipping image pull."
fi

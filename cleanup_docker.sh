#!/usr/bin/env bash

# Docker cleanup script to reclaim disk space
# Run this when Docker volumes are consuming too much space

set -e

echo "🧹 Docker Cleanup Script"
echo "========================"
echo

# Show current usage
echo "Current Docker disk usage:"
docker system df
echo

# Ask for confirmation
read -p "This will remove unused volumes, images, and build cache. Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo
echo "1️⃣ Removing unused volumes..."
docker volume prune -f

echo
echo "2️⃣ Removing unused images and containers..."
docker system prune -af

echo
echo "3️⃣ Removing build cache..."
docker buildx prune -af 2>/dev/null || docker builder prune -af

echo
echo "✅ Cleanup completed!"
echo
echo "New Docker disk usage:"
docker system df

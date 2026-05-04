#!/bin/bash
set -euo pipefail

HOST="loungebox"
REPO_PATH="/home/lounge/loungebox"
COMMAND="${1:-deploy}"

case "$COMMAND" in
  deploy)
    echo "Deploying to $HOST..."
    ssh "$HOST" "cd $REPO_PATH && git pull && sudo nixos-rebuild switch --flake .#loungebox"
    echo "Done."
    ;;
  update)
    echo "Updating nixpkgs..."
    nix flake update
    git add flake.lock && git commit -m "update nixpkgs"
    git push
    echo "Deploying to $HOST..."
    ssh "$HOST" "cd $REPO_PATH && git pull && sudo nixos-rebuild switch --flake .#loungebox"
    echo "Done."
    ;;
  rollback)
    echo "Rolling back $HOST to previous generation..."
    ssh "$HOST" "sudo nixos-rebuild switch --rollback"
    echo "Done."
    ;;
  *)
    echo "Usage: ./deploy.sh [deploy|update|rollback]"
    echo "  deploy   - Pull latest config and rebuild (default)"
    echo "  update   - Update nixpkgs, rebuild, and deploy"
    echo "  rollback - Switch to the previous NixOS generation"
    exit 1
    ;;
esac

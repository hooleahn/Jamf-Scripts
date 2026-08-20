#!/bin/bash

# This script finds all the Jamf Pro policies where a given script is used. It can also find all the scripts that are used in any given policy.

# Usage:
# ./script_lookup.sh <script_name>

# Example:
# ./script_lookup.sh "Super 5.1.1"

# This script uses the following command to find the policies where the script is used:
# jamf-cli pro classic-policies get <policy-id> -o json | jq '.scripts | select(.[].name | test("<script-name>"; "i"))'

# It also uses the following command to find the scripts that are used in any given policy:
# jamf-cli pro classic-policies get <policy-id> -o json | jq '.scripts | select(.[].name | test("<script-name>"; "i"))'

# It requires Jamf-CLI (https://github.com/Jamf-Concepts/jamf-cli) to be installed.

function echo_in_place()
{
    echo -ne "$1 \033[0K\r"
    sleep 0.1
}

if [ -z "$1" ]; then
    echo "No script name provided"
    echo "Pulling all policies and scripts"
    policies=$(jamf-cli pro classic-policies list -o json | jq '.[] | .id')
    for policy in $policies; do
        echo "Policy: $policy"
        scripts=$(jamf-cli pro classic-policies get $policy -o json | jq '.scripts | .[].name')
        for script in $scripts; do
            echo "Script: $script"
        done
    done
else
    echo "Finding policies where $1 is used"
    script_name="$1"

    echo "Checking first that the script exists"
    # jamf-cli pro scripts list -o json --select=name --quiet
    script_exists=$(jamf-cli pro scripts list -o json --select=name --quiet | jq --arg script_name "$script_name" '.[] | select(.name == $script_name)')
    if [ -z "$script_exists" ]; then
        echo "Script \"$script_name\" not found"
        exit 1
    fi
    echo "Script \"$script_name\" found. Checking for policies that use it..."
    policy_list=$(jamf-cli pro classic-policies list -o json --quiet)
    policy_count=$(echo $policy_list | jq '. | length')
    policy_ids=$(echo $policy_list | jq '.[] | .id')
    policy_names=$(echo $policy_list | jq '.[] | .name')
    echo "Found $policy_count policies"
    valid_policies=()
    counter=0
    for policy_id in $policy_ids; do
        # echo "Debug: $policy_id"
        policy_name=$(echo $policy_list | jq ".[] | select(.id == $policy_id) | .name")
        echo_in_place "Checking Policy: $policy_name ($policy_id) for script: \"$script_name\" ([$counter/$policy_count])"
        scripts=$(jamf-cli pro classic-policies get $policy_id -o json | jq --arg script_name "$script_name" '.scripts | select(.[].name == $script_name)')
        if [ -n "$scripts" ]; then
            valid_policies+=("$policy_id: $policy_name")
            echo_in_place "Script found in Policy: \"$policy_name\" ($policy_id)"
        fi
        counter=$((counter+1))
    done
    if [ ${#valid_policies[@]} -gt 0 ]; then
        echo "Script \"$script_name\" found in the following policies:"
        for policy in "${valid_policies[@]}"; do
            echo "$policy"
        done
    else
        echo "Script \"$script_name\" not found in any policies"
    fi
fi
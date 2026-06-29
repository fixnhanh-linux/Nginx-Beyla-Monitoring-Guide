#!/bin/bash
# Script to generate continuous heavy traffic for Beyla/Grafana Dashboard Demo
# This script simulates a real-world microservice ecosystem: fixcham.cloud

echo "Starting heavy continuous traffic generator..."
echo "Simulating traffic to api.fixcham.cloud, auth.fixcham.cloud, payments.fixcham.cloud..."

# Run 5 parallel workers
for i in {1..5}; do
  (
    while true; do
      # 1. API traffic (Success)
      curl -s -H "Host: api.fixcham.cloud" http://localhost:8080/api/v1/users > /dev/null
      
      # 2. Auth traffic (Success)
      curl -s -H "Host: auth.fixcham.cloud" http://localhost:8080/login > /dev/null
      
      # 3. Payments traffic (Success)
      curl -s -H "Host: payments.fixcham.cloud" http://localhost:8080/checkout > /dev/null
      
      # 4. API Error traffic (Simulates 500 Internal Server Error)
      curl -s -H "Host: api.fixcham.cloud" http://localhost:8080/api/500 > /dev/null
      
      # 5. Static files traffic (Simulates 404 Not Found)
      curl -s -H "Host: static.fixcham.cloud" http://localhost:8080/images/not-found.png > /dev/null
      
      sleep 0.5
    done
  ) &
done

echo "Heavy traffic generator is running in the background with 5 parallel workers."
echo "Press [CTRL+C] to stop this script and kill background jobs."

# Wait for all background jobs to finish (which is never, unless killed)
wait

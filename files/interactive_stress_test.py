#!/usr/bin/env python
import argparse
import asyncio
import time
import httpx
import numpy as np
import random
import string
import subprocess
import sys
import atexit
import json
from types import SimpleNamespace

# --- Configuration ---
# These values are based on the Kubernetes services you provided.
NAMESPACE = "llm-d"
SERVICE_NAME = "llm-d-inference-gateway-istio"
LOCAL_PORT = 8080
BASE_URL = f"http://localhost:{LOCAL_PORT}"

# Global variable to hold the port-forwarding process
port_forward_process = None

# --- Helper & Utility Functions ---

def print_header(title):
    """Prints a styled header."""
    print("\n" + "="*50)
    print(f"  {title}")
    print("="*50)

def get_user_input(prompt_text, default, type_converter=str):
    """Prompts the user for input with a default value."""
    while True:
        user_input = input(f"➡️  {prompt_text} [{default}]: ")
        if not user_input:
            return default
        try:
            return type_converter(user_input)
        except ValueError:
            print(f"❌ Invalid input. Please enter a value of type {type_converter.__name__}.")

def start_port_forward():
    """Starts 'kubectl port-forward' as a background process."""
    global port_forward_process
    if port_forward_process:
        return True # Already running

    print(f"🔍 Starting port-forward to {SERVICE_NAME} in namespace {NAMESPACE}...")
    command = [
        "kubectl", "port-forward",
        "-n", NAMESPACE,
        f"svc/{SERVICE_NAME}",
        f"{LOCAL_PORT}:80"
    ]
    try:
        port_forward_process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        # Register a function to kill the process upon script exit
        atexit.register(stop_port_forward)
        print(f"✅ Port-forwarding active on pid {port_forward_process.pid}.")
        # Give it a moment to establish the connection
        time.sleep(2)
        return True
    except FileNotFoundError:
        print("❌ Error: 'kubectl' command not found.")
        print("Please ensure kubectl is installed and in your system's PATH.")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error starting port-forward: {e}")
        sys.exit(1)

def stop_port_forward():
    """Stops the background 'kubectl port-forward' process if it's running."""
    global port_forward_process
    if port_forward_process:
        print("\n gracefully shutting down port-forwarding...")
        port_forward_process.terminate()
        port_forward_process.wait()
        port_forward_process = None
        print("✅ Port-forwarding stopped.")

def detect_models():
    """Detects available models by querying the /v1/models endpoint."""
    print("🔍 Detecting available models...")
    try:
        response = httpx.get(f"{BASE_URL}/v1/models", timeout=5.0)
        response.raise_for_status()
        models = response.json().get("data", [])
        model_ids = [m.get("id") for m in models if m.get("id")]

        if not model_ids:
            print("❌ Error: No models found at the endpoint.")
            sys.exit(1)

        print(f"✅ Found models: {model_ids}")
        if len(model_ids) == 1:
            return model_ids[0]
        else:
            # Let the user choose if there are multiple models
            print("Please choose a model to use for the test:")
            for i, model_id in enumerate(model_ids):
                print(f"  {i+1}: {model_id}")
            choice = get_user_input("Enter model number", 1, int) - 1
            return model_ids[choice]

    except (httpx.RequestError, json.JSONDecodeError) as e:
        print(f"❌ Error: Could not connect to the gateway at {BASE_URL}.")
        print("   Please ensure the service is running and port-forwarding is working.")
        print(f"   Details: {e}")
        sys.exit(1)

# (The core testing logic from the previous script remains the same)
# --- Core Request Logic (send_request, print_report, etc.) ---
def generate_random_prompt(length: int) -> str:
    words=["explain","how","to","build","a","fast","car","using","python","what","is","the","capital","of","mongolia","tell","me","a","story","about","a","dragon","and","a","knight","the","meaning","of","life"]
    return " ".join(random.choices(words,k=length//5))
def print_final_report(results:list,duration:float,total_requests:int):
    if not results:print("No results to report.");return
    successful_results=[r for r in results if r.get("e2e_latency")]
    if not successful_results:print("No successful requests to report.");return
    e2e_latencies=[r["e2e_latency"]for r in successful_results]
    ttft_latencies=[r["ttft"]for r in successful_results if r.get("ttft")]
    time_per_token_latencies=[r["time_per_token"]for r in successful_results if r.get("time_per_token")]
    total_prompt_tokens=sum(r["prompt_tokens"]for r in successful_results)
    total_generated_tokens=sum(r["generated_tokens"]for r in successful_results)
    print_header("E2E Request Latency")
    print(f"P99: {np.percentile(e2e_latencies,99):.4f}s");print(f"P95: {np.percentile(e2e_latencies,95):.4f}s");print(f"P90: {np.percentile(e2e_latencies,90):.4f}s");print(f"P50 (Median): {np.median(e2e_latencies):.4f}s");print(f"Average: {np.mean(e2e_latencies):.4f}s")
    if ttft_latencies:print_header("Time To First Token Latency (Streaming)");print(f"P99: {np.percentile(ttft_latencies,99):.4f}s");print(f"P95: {np.percentile(ttft_latencies,95):.4f}s");print(f"P90: {np.percentile(ttft_latencies,90):.4f}s");print(f"P50 (Median): {np.median(ttft_latencies):.4f}s");print(f"Average: {np.mean(ttft_latencies):.4f}s")
    if time_per_token_latencies:print_header("Time Per Output Token Latency (Streaming)");print(f"P99: {np.percentile(time_per_token_latencies,99)*1000:.4f}ms");print(f"P95: {np.percentile(time_per_token_latencies,95)*1000:.4f}ms");print(f"P90: {np.percentile(time_per_token_latencies,90)*1000:.4f}ms");print(f"P50 (Median): {np.median(time_per_token_latencies)*1000:.4f}ms");print(f"Mean: {np.mean(time_per_token_latencies)*1000:.4f}ms")
    print_header("Token Throughput")
    print(f"Overall RPS: {total_requests/duration:.2f} req/s");print(f"Prompt Tokens/Sec: {total_prompt_tokens/duration:.2f}");print(f"Generation Tokens/Sec: {total_generated_tokens/duration:.2f}")
    finish_reasons=[r.get("finish_reason","client_abort")for r in results];reason_counts={reason:finish_reasons.count(reason)for reason in set(finish_reasons)}
    print_header("Finish Reason")
    for reason,count in reason_counts.items():print(f"{reason}: {count} ({count/total_requests*100:.1f}%)")
async def send_request(client:httpx.AsyncClient,url:str,model:str,prompt:str,max_tokens:int,stream:bool)->dict:
    payload={"model":model,"prompt":prompt,"max_tokens":max_tokens,"stream":stream}
    result={};request_start_time=time.monotonic()
    try:
        if stream:
            ttft=None;generated_tokens=0;finish_reason="unknown"
            async with client.stream("POST",url,json=payload,timeout=60.0)as response:
                async for chunk in response.aiter_bytes():
                    if ttft is None:ttft=time.monotonic()-request_start_time
            e2e_latency=time.monotonic()-request_start_time
            result={"e2e_latency":e2e_latency,"ttft":ttft,"generated_tokens":max_tokens,"prompt_tokens":len(prompt.split()),"finish_reason":"length"}
            if ttft and max_tokens>1:result["time_per_token"]=(e2e_latency-ttft)/(max_tokens-1)
        else:
            response=await client.post(url,json=payload,timeout=60.0)
            response.raise_for_status()
            e2e_latency=time.monotonic()-request_start_time;data=response.json()
            prompt_tokens=data.get("usage",{}).get("prompt_tokens",len(prompt.split()));generated_tokens=data.get("usage",{}).get("completion_tokens",0);finish_reason=data["choices"][0].get("finish_reason","unknown")
            result={"e2e_latency":e2e_latency,"ttft":e2e_latency,"generated_tokens":generated_tokens,"prompt_tokens":prompt_tokens,"finish_reason":finish_reason}
    except httpx.TimeoutException:result={"finish_reason":"client_abort"}
    except httpx.RequestError as e:result={"finish_reason":f"client_error: {e.__class__.__name__}"}
    except Exception as e:result={"finish_reason":f"unexpected_error: {e.__class__.__name__}"}
    return result
async def run_test_async(args):
    print_header(f"🚀 Running Test: {args.test_name}")
    print(f"   Concurrency: {args.concurrency}, Requests: {args.num_requests}, Prompt Length: {args.prompt_length}, Max Tokens: {args.max_tokens}, Stream: {args.stream}")
    semaphore=asyncio.Semaphore(args.concurrency)
    async def limited_request(*args,**kwargs):
        async with semaphore:return await send_request(*args,**kwargs)
    async with httpx.AsyncClient()as client:
        prompts=[generate_random_prompt(args.prompt_length)for _ in range(args.num_requests)]
        start_time=time.monotonic()
        tasks=[limited_request(client,f"{BASE_URL}/v1/completions",args.model,p,args.max_tokens,args.stream)for p in prompts]
        results=await asyncio.gather(*tasks,return_exceptions=True)
        duration=time.monotonic()-start_time
    print(f"\n✅ Test finished in {duration:.2f} seconds.")
    print_final_report([r for r in results if isinstance(r,dict)],duration,args.num_requests)

# --- Interactive Test Definitions ---

def run_throughput_test(model):
    print("\n--- Throughput Test ---")
    print("This test uses moderate concurrency and small prompts/responses to measure the maximum requests per second (RPS) and token throughput.")
    args = SimpleNamespace()
    args.test_name = "Throughput Test"
    args.model = model
    args.num_requests = get_user_input("Number of requests", 200, int)
    args.concurrency = get_user_input("Concurrency level", 20, int)
    args.prompt_length = get_user_input("Prompt word count", 50, int)
    args.max_tokens = get_user_input("Max new tokens", 60, int)
    args.stream = False
    asyncio.run(run_test_async(args))

def run_latency_test(model):
    print("\n--- Latency (Streaming) Test ---")
    print("This test uses low concurrency and streaming to accurately measure Time to First Token (TTFT) and per-token generation latency.")
    args = SimpleNamespace()
    args.test_name = "Latency (Streaming) Test"
    args.model = model
    args.num_requests = get_user_input("Number of requests", 50, int)
    args.concurrency = get_user_input("Concurrency level", 5, int)
    args.prompt_length = get_user_input("Prompt word count", 256, int)
    args.max_tokens = get_user_input("Max new tokens", 512, int)
    args.stream = True
    asyncio.run(run_test_async(args))

def run_scheduler_stress_test(model):
    print("\n--- Scheduler Stress Test ---")
    print("This test uses very high concurrency to create a request queue, testing the scheduler's ability to handle overload. Expect high P99 latencies.")
    args = SimpleNamespace()
    args.test_name = "Scheduler Stress Test"
    args.model = model
    args.num_requests = get_user_input("Number of requests", 500, int)
    args.concurrency = get_user_input("Concurrency level", 150, int)
    args.prompt_length = get_user_input("Prompt word count", 10, int)
    args.max_tokens = get_user_input("Max new tokens", 10, int)
    args.stream = False
    asyncio.run(run_test_async(args))

# --- Main Execution Block ---

def main():
    """Main function to run the interactive test suite."""
    try:
        print_header("LLM Interactive Stress Test Suite")
        start_port_forward()
        model = detect_models()

        while True:
            print_header("Test Menu")
            print("1: Throughput Test (High RPS, non-streaming)")
            print("2: Latency Test (TTFT, streaming)")
            print("3: Scheduler Stress Test (High concurrency)")
            print("4: Exit")
            choice = get_user_input("Select a test to run", "1", str)

            if choice == '1':
                run_throughput_test(model)
            elif choice == '2':
                run_latency_test(model)
            elif choice == '3':
                run_scheduler_stress_test(model)
            elif choice == '4':
                break
            else:
                print("❌ Invalid choice, please try again.")
    finally:
        # This ensures cleanup happens even if the user Ctr-C's out of the program
        stop_port_forward()

if __name__ == "__main__":
    main()
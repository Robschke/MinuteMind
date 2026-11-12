import json
import sys

def extract_crash(ips_path):
    with open(ips_path, 'r') as f:
        content = f.read()
    
    # Skip the first JSON object (header)
    first_brace = content.find('{')
    if first_brace == -1:
        print("No JSON found")
        return
        
    # Search for the second {
    second_brace = content.find('{', first_brace + 1)
    if second_brace == -1:
        # Maybe there is only one JSON?
        json_str = content[first_brace:]
    else:
        json_str = content[second_brace:]
    
    # Clean up trailing text if any
    last_brace = json_str.rfind('}')
    if last_brace != -1:
        json_str = json_str[:last_brace+1]
        
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"JSON Decode Error: {e}")
        # Try finding where it might have failed
        return

    fault_thread_idx = data.get('faultingThread', 0)
    threads = data.get('threads', [])
    
    print(f"Total Threads: {len(threads)}")
    print(f"Faulting Thread Index: {fault_thread_idx}")
    
    if fault_thread_idx < len(threads):
        thread = threads[fault_thread_idx]
        thread_id = thread.get('id', 'N/A')
        thread_name = thread.get('name', 'Main Thread?')
        print(f"\n--- Thread {fault_thread_idx} (ID: {thread_id}, Name: {thread_name}) (CRASHED) ---")
        
        frames = thread.get('frames', [])
        for frame in frames:
            image_index = frame.get('imageIndex', -1)
            symbol = frame.get('symbol', '???')
            image_name = "Unknown"
            if 'usedImages' in data and image_index < len(data['usedImages']):
                image_name = data['usedImages'][image_index].get('name', 'Unknown')
            
            print(f"  {image_name}: {symbol}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        extract_crash(sys.argv[1])

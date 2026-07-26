import csv
import sys

def summarize_wpa_tree(filename, limit=100):
    try:
        with open(filename, mode='r', encoding='utf-8') as csvfile:
            reader = csv.reader(csvfile)
            next(reader, None) # Skip header
            print(f"{'Hierarchy/Function':<100} | {'Count':<15} | {'Weight (ms)':<20}")
            print("-" * 138)

            count_rows = 0
            for row in reader:
                if len(row) < 10: continue
                stack_info = row[3]
                count_val = row[6]
                weight_str = row[7].replace(',', '')
                if not stack_info: continue
                
                # Reduce indentation: replace '|    ' with '| ' and '  |- ' with '|- '
                cleaned_stack = stack_info.replace('|    ', '| ').replace('  |-', '|-')
                
                try:
                    weight = float(weight_str)
                    print(f"{cleaned_stack[:100]:<100} | {count_val:<15} | {weight:<20.3f}")
                    count_rows += 1
                except ValueError: continue
                if count_rows >= limit: break
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    summarize_wpa_tree(sys.argv[1]) if len(sys.argv) > 1 else print("Usage: python summarize_wpa.py <file>")

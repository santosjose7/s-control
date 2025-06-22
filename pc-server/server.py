import socket
import threading
import pyautogui
import tkinter as tk
from tkinter import filedialog, ttk, messagebox
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import urllib.parse
import mimetypes

# Get LAN IP instead of localhost/127.0.x.x
def get_lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # Doesn't need to reach
        return s.getsockname()[0]
    finally:
        s.close()

HOST = get_lan_ip()
TCP_PORT = 5000
HTTP_PORT = 5001
file_to_send = None
upload_folder = "uploads"
os.makedirs(upload_folder, exist_ok=True)

class RemoteControlServer:
    def __init__(self):
        self.clients = []

    def start_tcp_server(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind((HOST, TCP_PORT))
        server.listen(5)
        print(f"[TCP] Listening on {HOST}:{TCP_PORT}")

        while True:
            client, addr = server.accept()
            print(f"[TCP] Connection from {addr}")
            client.send(f"{socket.gethostname()}\n".encode())
            threading.Thread(target=self.handle_client, args=(client,), daemon=True).start()

    def handle_client(self, client):
        buffer = ""
        with client:
            while True:
                try:
                    chunk = client.recv(1024).decode()
                    if not chunk:
                        break
                    buffer += chunk
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if line:
                            print(f"[TCP] Received: {line}")
                            self.process_command(line)
                except Exception as e:
                    print(f"[TCP] Error: {e}")
                    break


    def process_command(self, msg):
        if msg.startswith("move:"):
            dx, dy = map(int, msg[5:].split(","))
            pyautogui.moveRel(dx * 3, dy * 3, duration=0)
        elif msg == "left_click":
            pyautogui.click()
        elif msg == "right_click":
            pyautogui.click(button='right')
        elif msg.startswith("scroll:"):
            direction = msg.split(":")[1]
            pyautogui.scroll(-100 if direction == 'down' else 100)
        elif msg.startswith("text:"):
            text = msg[5:]
            pyautogui.write(text)
        elif msg.startswith("key:"):
            key = msg[4:]
            pyautogui.press(key)
        elif msg.startswith("media:"):
            media = msg[6:]
            if media == "play_pause":
                pyautogui.press("playpause")
            elif media == "next":
                pyautogui.press("nexttrack")
            elif media == "prev":
                pyautogui.press("prevtrack")
        elif msg.startswith("down:"):
            key = msg[5:]
            pyautogui.keyDown(key)
        elif msg.startswith("up:"):
            key = msg[3:]
            pyautogui.keyUp(key)

def start_http_server():
    class FileHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/getfile" and file_to_send:
                self.send_response(200)
                mime = mimetypes.guess_type(file_to_send)[0] or 'application/octet-stream'
                self.send_header("Content-type", mime)
                self.send_header("Content-Disposition", f"attachment; filename={os.path.basename(file_to_send)}")
                self.end_headers()
                with open(file_to_send, 'rb') as f:
                    self.wfile.write(f.read())
            else:
                self.send_error(404, "File Not Found")

        def do_POST(self):
            if self.path == "/upload":
                length = int(self.headers['Content-Length'])
                boundary = self.headers['Content-Type'].split("=")[-1]
                data = self.rfile.read(length)
                parts = data.split(b"--" + boundary.encode())
                for part in parts:
                    if b"filename=" in part:
                        header, file_data = part.split(b"\r\n\r\n", 1)
                        file_data = file_data.rstrip(b"--\r\n")
                        filename = header.split(b'filename="')[1].split(b'"')[0].decode()
                        filepath = os.path.join(upload_folder, filename)
                        with open(filepath, "wb") as f:
                            f.write(file_data)
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b"Upload complete")
                        print(f"[HTTP] Uploaded: {filename}")
                        return
                self.send_error(400, "Invalid Upload")
            else:
                self.send_error(404, "Not Found")

    httpd = HTTPServer((HOST, HTTP_PORT), FileHandler)
    print(f"[HTTP] Serving HTTP on {HOST}:{HTTP_PORT}")
    httpd.serve_forever()

class AppGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("PC Remote Control Server")
        self.root.geometry("400x200")
        self.file_label = tk.Label(root, text="No file selected")
        self.file_label.pack(pady=10)

        tk.Button(root, text="Choose File to Send", command=self.choose_file).pack(pady=5)
        self.progress = ttk.Progressbar(root, mode='determinate', length=300)
        self.progress.pack(pady=10)
        self.info = tk.Label(root, text=f"Server running at:\nTCP: {HOST}:{TCP_PORT}\nHTTP: {HOST}:{HTTP_PORT}")
        self.info.pack(pady=5)

    def choose_file(self):
        global file_to_send
        path = filedialog.askopenfilename()
        if path:
            file_to_send = path
            self.file_label.config(text=os.path.basename(path))
            self.progress.start(10)
            messagebox.showinfo("Ready", "Phone can now download the file using the app.")
        else:
            self.file_label.config(text="No file selected")

if __name__ == "__main__":
    server = RemoteControlServer()
    threading.Thread(target=server.start_tcp_server, daemon=True).start()
    threading.Thread(target=start_http_server, daemon=True).start()

    root = tk.Tk()
    gui = AppGUI(root)
    root.mainloop()


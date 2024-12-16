import sys
import os
import tempfile
import queue
import sounddevice as sd
import numpy as np
import wave
from scipy import signal
from datetime import datetime
from dotenv import load_dotenv
import openai
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout,
    QPushButton, QLabel, QComboBox, QSpinBox, QTextEdit
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal

# Load environment variables
load_dotenv()
openai.api_key = os.getenv('OPENAI_API_KEY')

class AudioProcessor:
    def __init__(self, threshold=0.01, silence_limit=2):
        self.threshold = threshold
        self.silence_limit = silence_limit
        self.sample_rate = 16000
        self.channels = 1
        self.dtype = np.int16
        self.chunk_size = 1024
        self.audio_queue = queue.Queue()
        self.temp_dir = tempfile.gettempdir()

    def audio_callback(self, indata, frames, time, status):
        if status:
            print(f"Status: {status}")
        self.audio_queue.put(indata.copy())

    def is_silent(self, audio_data, threshold):
        return np.max(np.abs(audio_data)) < threshold

    def save_audio(self, audio_data, filename):
        with wave.open(filename, 'wb') as wf:
            wf.setnchannels(self.channels)
            wf.setsampwidth(2)  # 16-bit audio
            wf.setframerate(self.sample_rate)
            wf.writeframes(audio_data.tobytes())

class TranscriptionThread(QThread):
    transcription_signal = pyqtSignal(str)
    error_signal = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self.is_running = False
        self.audio_processor = AudioProcessor()
        self.language = "en"
        self.threshold = 0.01

    def set_language(self, lang):
        self.language = lang

    def set_threshold(self, threshold):
        self.threshold = threshold / 5000.0  # Convert from UI value (0-100) to float

    def run(self):
        self.is_running = True
        try:
            with sd.InputStream(
                channels=self.audio_processor.channels,
                samplerate=self.audio_processor.sample_rate,
                dtype=self.audio_processor.dtype,
                blocksize=self.audio_processor.chunk_size,
                callback=self.audio_processor.audio_callback
            ):
                self.transcription_signal.emit("Started listening...")
                
                audio_buffer = []
                silence_counter = 0
                
                while self.is_running:
                    try:
                        audio_chunk = self.audio_processor.audio_queue.get(timeout=1)
                        
                        # Convert to float for better processing
                        audio_chunk_float = audio_chunk.astype(np.float32) / 32768.0
                        
                        if self.audio_processor.is_silent(audio_chunk_float, self.threshold):
                            silence_counter += 1
                        else:
                            silence_counter = 0
                            
                        audio_buffer.append(audio_chunk)
                        
                        # If we've detected enough silence or the buffer is getting too large
                        if (silence_counter > self.audio_processor.silence_limit * 
                            (self.audio_processor.sample_rate / self.audio_processor.chunk_size) or 
                            len(audio_buffer) > 50):  # ~3 seconds max
                            
                            if len(audio_buffer) > 2:  # Only process if we have enough audio
                                # Combine all audio chunks
                                audio_data = np.concatenate(audio_buffer)
                                
                                # Save to temporary file
                                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                                temp_file = os.path.join(
                                    self.audio_processor.temp_dir,
                                    f"audio_{timestamp}.wav"
                                )
                                self.audio_processor.save_audio(audio_data, temp_file)
                                
                                # Transcribe using Whisper API
                                try:
                                    with open(temp_file, "rb") as audio_file:
                                        response = openai.Audio.transcribe(
                                            "whisper-1",
                                            audio_file,
                                            language=self.language
                                        )
                                        if response and response.get("text"):
                                            self.transcription_signal.emit(response["text"].strip())
                                except Exception as e:
                                    self.error_signal.emit(f"Transcription error: {str(e)}")
                                
                                # Clean up
                                os.remove(temp_file)
                            
                            # Reset buffers
                            audio_buffer = []
                            silence_counter = 0
                            
                    except queue.Empty:
                        continue
                    except Exception as e:
                        self.error_signal.emit(f"Processing error: {str(e)}")
                        
        except Exception as e:
            self.error_signal.emit(f"Audio system error: {str(e)}")
        
        self.transcription_signal.emit("Stopped listening.")

    def stop(self):
        self.is_running = False

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Whisper Stream")
        self.setMinimumSize(800, 600)
        
        # Create main widget and layout
        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        layout = QVBoxLayout(main_widget)
        
        # Create controls
        self.create_controls(layout)
        
        # Create transcription display
        self.transcription_display = QTextEdit()
        self.transcription_display.setReadOnly(True)
        layout.addWidget(self.transcription_display)
        
        # Initialize transcription thread
        self.transcription_thread = TranscriptionThread()
        self.transcription_thread.transcription_signal.connect(self.update_transcription)
        self.transcription_thread.error_signal.connect(self.show_error)

    def create_controls(self, layout):
        # Language selection
        lang_layout = QVBoxLayout()
        lang_label = QLabel("Input Language:")
        self.lang_combo = QComboBox()
        self.lang_combo.addItems(["en", "ja", "es", "fr", "de"])
        self.lang_combo.currentTextChanged.connect(self.update_language)
        lang_layout.addWidget(lang_label)
        lang_layout.addWidget(self.lang_combo)
        layout.addLayout(lang_layout)

        # Volume threshold
        threshold_layout = QVBoxLayout()
        threshold_label = QLabel("Volume Threshold:")
        self.threshold_spin = QSpinBox()
        self.threshold_spin.setRange(0, 100)
        self.threshold_spin.setValue(50)
        self.threshold_spin.valueChanged.connect(self.update_threshold)
        threshold_layout.addWidget(threshold_label)
        threshold_layout.addWidget(self.threshold_spin)
        layout.addLayout(threshold_layout)

        # Start/Stop button
        self.toggle_button = QPushButton("Start Transcription")
        self.toggle_button.clicked.connect(self.toggle_transcription)
        layout.addWidget(self.toggle_button)

    def update_language(self, language):
        self.transcription_thread.set_language(language)

    def update_threshold(self, value):
        self.transcription_thread.set_threshold(value)

    def toggle_transcription(self):
        if not self.transcription_thread.is_running:
            self.transcription_thread.start()
            self.toggle_button.setText("Stop Transcription")
        else:
            self.transcription_thread.stop()
            self.toggle_button.setText("Start Transcription")

    def update_transcription(self, text):
        self.transcription_display.append(text)

    def show_error(self, error_message):
        self.transcription_display.append(f"Error: {error_message}")

def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main() 
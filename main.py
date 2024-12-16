import sys
import os
from dotenv import load_dotenv
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout,
    QPushButton, QLabel, QComboBox, QSpinBox, QTextEdit
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal

# Load environment variables
load_dotenv()

class TranscriptionThread(QThread):
    transcription_signal = pyqtSignal(str)
    error_signal = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self.is_running = False

    def run(self):
        self.is_running = True
        # TODO: Implement transcription logic
        pass

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
        self.lang_combo.addItems(["en", "ja", "es", "fr", "de"])  # Add more languages as needed
        lang_layout.addWidget(lang_label)
        lang_layout.addWidget(self.lang_combo)
        layout.addLayout(lang_layout)

        # Volume threshold
        threshold_layout = QVBoxLayout()
        threshold_label = QLabel("Volume Threshold:")
        self.threshold_spin = QSpinBox()
        self.threshold_spin.setRange(0, 100)
        self.threshold_spin.setValue(50)
        threshold_layout.addWidget(threshold_label)
        threshold_layout.addWidget(self.threshold_spin)
        layout.addLayout(threshold_layout)

        # Start/Stop button
        self.toggle_button = QPushButton("Start Transcription")
        self.toggle_button.clicked.connect(self.toggle_transcription)
        layout.addWidget(self.toggle_button)

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
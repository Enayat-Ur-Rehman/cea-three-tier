import os
import sys

# Make app.py importable as the "app" module when pytest runs from any folder
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

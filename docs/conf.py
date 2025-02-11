"""
Configuration file for the Sphinx documentation builder.

For the full list of built-in configuration values, see the documentation:
https://www.sphinx-doc.org/en/master/usage/configuration.html

-- Project information -----------------------------------------------------
https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information
"""

import os
import sys

sys.path.insert(0, os.path.abspath("../"))
sys.path.insert(0, os.path.abspath("../src"))


project = "PROJECT_NAME"
copyright = "2024, Heitor Polidoro"
author = "Heitor Polidoro"

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = [
    "myst_parser",
    "sphinx.ext.autodoc",
    "sphinx.ext.autosummary",
    "sphinx_copybutton",
    "sphinx.ext.napoleon",
]
myst_enable_extensions = ["colon_fence", "fieldlist"]

pygments_style = "sphinx"

exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# Whether to prepend module names to object names in `.. autoclass::` etc.
add_module_names = False
# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = "sphinx_rtd_theme"
html_theme_options = {
    "titles_only": True,
}

napoleon_google_docstring = True
autodoc_member_order = "bysource"

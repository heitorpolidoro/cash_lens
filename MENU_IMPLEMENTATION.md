# Left Menu Implementation Documentation

## Overview
This document describes the implementation of a left menu (sidebar) in the CashLens application. The menu provides easy navigation to key sections of the application and is responsive across different screen sizes.

## Changes Made

### 1. Modified Layout Structure
The main layout file (`app.html.heex`) was updated to include a left sidebar while maintaining the existing header. The layout now consists of:
- Header at the top
- Left sidebar for navigation
- Main content area

### 2. Menu Items
The following navigation items were added to the left menu:
- **Home** - Links to the root path (`/`)
- **Accounts** - Links to the accounts list (`/accounts`)
- **New Account** - Links to the account creation form (`/accounts/new`)

Each menu item includes an appropriate icon for better visual recognition.

### 3. Responsive Design
The menu is fully responsive:
- On desktop/large screens (lg breakpoint and above):
  - The sidebar is always visible on the left side
  - Main content adjusts to accommodate the sidebar width
- On mobile/small screens (below lg breakpoint):
  - The sidebar is hidden by default
  - A hamburger menu button appears in the top-left corner
  - Clicking the button toggles the sidebar visibility
  - The sidebar slides in from the left with a smooth transition

### 4. Implementation Details

#### TailwindCSS Classes
- Used `w-64` for sidebar width
- Used `fixed` positioning on mobile and `static` on desktop
- Used transform with `-translate-x-full` to hide the sidebar on mobile
- Added `transition duration-200 ease-in-out` for smooth animations
- Used `z-index` to ensure proper layering

#### JavaScript Functionality
Added JavaScript to handle the mobile menu toggle:
- Listens for clicks on the mobile menu button
- Toggles the sidebar's visibility by adding/removing CSS classes
- Uses `translate-x-0` and `-translate-x-full` classes to show/hide the sidebar

## Future Enhancements
Potential future enhancements for the menu could include:
- Active state styling for the current page
- Nested menu items for more complex navigation
- User profile section in the sidebar
- Collapsible sidebar option
- Dark mode support

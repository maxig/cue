# Vibe Research: Loom vs. Cap.so

This document captures the design language, user interface patterns, and overall 'vibe' of two leading video communication tools: **Loom** and **Cap.so**.

---

## 1. Menubar Interaction Patterns

### **Loom: The "Floating Extension" Pattern**
*   **Vibe:** Utility-first, persistent, and accessible.
*   **Behavior:** On macOS/Windows, Loom lives as a dedicated menubar icon that triggers a floating widget. The widget provides immediate feedback on microphone levels and recording modes.
*   **UI Components:**
    *   Rounded rectangular window with clear "Screen + Cam", "Screen Only", and "Cam Only" tabs.
    *   Large, unmistakable "Start Recording" button (often in Loom's signature purple).
    *   **Visual Asset:** [Loom Desktop App UI](https://www.loom.com/media-kit) (Official Media Kit).

### **Cap.so: The "Native Utility" Pattern**
*   **Vibe:** Sleek, minimalist, and deeply integrated with the OS.
*   **Behavior:** Cap feels more like a native macOS utility (similar to CleanShot X). It uses a dropdown menu pattern that feels lighter and less intrusive than Loom's floating window.
*   **UI Components:**
    *   List-style menu with keyboard shortcuts (e.g., `⌘⇧2`) displayed alongside actions.
    *   Toggle-able menu items to reduce clutter.
    *   **Visual Asset:** [Cap.so Brand Resources](https://brandfetch.com/cap.so).

---

## 2. Video Overlay Styles (Face Cam)

### **Loom: The Circular Bubble**
*   **Style:** A fixed circular mask for the webcam.
*   **Interaction:** Users can move the bubble around the screen *during* recording. It can be resized to three preset sizes or switched to a static profile picture.
*   **Vibe:** Iconic but "baked-in." What you see during recording is largely what you get in the final video.

### **Cap.so: The Multi-Track Studio Overlay**
*   **Style:** Circular or rounded-rect webcam overlay.
*   **Interaction:** Unlike Loom, Cap often records the webcam as a **separate track**. This allows for "Studio Mode" where the face cam can be repositioned, resized, or even toggled off *after* the recording is finished.
*   **Vibe:** High production value. It looks like it was edited in a professional studio, but it happens automatically.

---

## 3. Sharing Page Layout

### **Loom: The Collaborative Feed**
*   **Layout:** A centralized video player with a heavy focus on social interaction.
    *   **Right Sidebar:** Contains comments, emoji reactions (timed to the video), and transcripts.
    *   **Header/Footer:** Clear CTAs (Call to Action) and branding.
*   **Vibe:** A "social network for work." It feels busy but highly functional for team feedback.
*   **Key Colors:** #625DF5 (Loom Purple), soft grays, and white.

### **Cap.so: The Minimalist Portfolio**
*   **Layout:** Ultra-clean, often defaulting to a dark mode aesthetic.
    *   **Player:** Takes center stage with generous whitespace (or padding with custom backgrounds).
    *   **Interactions:** Comments and reactions are present but tucked away to prioritize the video content.
*   **Vibe:** Premium and creator-focused. It feels like a high-end portfolio piece rather than a internal work memo.
*   **Customization:** Supports custom domains and branded "S3" hosting for a fully white-label feel.

---

## 4. Post-Recording Editing & AI Features

### **Loom AI: Workflow Optimizer**
*   **Features:**
    *   **Auto-Summaries:** Generates titles and descriptions.
    *   **Jira Integration:** Automatically converts a video into a technical bug report with metadata.
    *   **Trimming:** Basic web-based timeline for cutting out "umms" and dead air.
*   **UI Vibe:** "Set it and forget it." The AI works in the background to save time.

### **Cap Studio: Creative Director**
*   **Features:**
    *   **Smooth Zoom:** Automatically zooms in on mouse clicks to emphasize actions.
    *   **Layouts:** Change backgrounds, add padding, and adjust "canvas" size for different platforms (TikTok/YouTube).
    *   **AI Chapters:** Generates clickable chapters and summaries for navigation.
*   **UI Vibe:** "Pro-sumer." It gives the user "one-click" superpowers that usually require a video editor.

---

## Summary of 'Vibes'

| Feature | Loom | Cap.so |
| :--- | :--- | :--- |
| **Primary Color** | Purple (#625DF5) | High-contrast Black/White |
| **Aesthetic** | Rounded, Friendly, SaaS-Standard | Sharp, Modern, Creator-Centric |
| **Best For** | Quick team updates & bug reports | Tutorials, demos, and marketing |
| **Aesthetic Vibe** | "Efficient Coworker" | "Polished Producer" |

---
*Research compiled for design team review.*

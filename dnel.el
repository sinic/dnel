;;; dnel.el --- Emacs Desktop Notifications server -*- lexical-binding: t; -*-
;; Copyright (C) 2020 Simon Nicolussi

;; Author: Simon Nicolussi <sinic@sinic.name>
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))
;; Keywords: unix
;; Homepage: https://github.com/sinic/dnel

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; DNel is an Emacs package that implements a Desktop Notifications
;; server in pure Lisp, aspiring to be a small, but flexible drop-in
;; replacement for standalone daemons like Dunst.  Active notifications
;; are tracked whenever the global minor mode `dnel-mode' is active and
;; can be retrieved as a list with the function `dnel-notifications'.
;; DNel also provides a hook `dnel-notifications-changed-functions', so
;; that users can handle newly added and removed notifications as they
;; see fit.  To be useful out of the box, DNel records past and present
;; notifications in the interactive log buffer `*dnel-log*'.

;;; Code:
(require 'cl-lib)
(require 'dbus)

(defconst dnel--log-name "*dnel-log*")

(defconst dnel--path "/org/freedesktop/Notifications")
(defconst dnel--service (subst-char-in-string ?/ ?. (substring dnel--path 1)))
(defconst dnel--interface dnel--service)

(cl-defstruct (dnel-notification (:constructor dnel--notification-create)
                                 (:copier nil))
  id app-name summary body actions image hints timer client
  log-position pop-suffix)

;;;###autoload
(define-minor-mode dnel-mode
  "Act as a Desktop Notifications server and track notifications."
  :global t :lighter " DNel"
  (if dnel-mode (dnel--start-server) (dnel--stop-server)))

(defvar dnel-notifications-changed-functions #'dnel--update-log-buffer
  "Functions in this list are called on changes to notifications.

Their arguments are the removed notification, if any,
followed by the newly added notification, if any.")

(defvar dnel--state (list 0)
  "The minor mode tracks all active desktop notifications here.

This object is currently implemented as a cons cell: its car is the
count of distinct IDs assigned so far, its cdr is a list of currently
active notifications, newest first.")

(defvar dnel-log-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'dnel-invoke-action)
    (define-key map (kbd "TAB") #'dnel-toggle-body-visibility)
    (define-key map "d" #'dnel-dismiss-notification)
    map)
  "Keymap for the DNel log buffer.")

(defun dnel-notifications ()
  "Return currently active notifications."
  (cdr dnel--state))

(defun dnel-invoke-action (notification &optional action)
  "Invoke ACTION of the NOTIFICATION.

ACTION defaults to the key \"default\"."
  (interactive (list (get-text-property (point) 'dnel-notification)))
  (unless (and notification (dnel-notification-pop-suffix notification))
    (user-error "No active notification at point"))
  (dnel--dbus-talk-to (dnel-notification-client notification) 'dbus-send-signal
                      "ActionInvoked" (dnel-notification-id notification)
                      (or action "default")))

(defun dnel-dismiss-notification (notification)
  "Dismiss the NOTIFICATION."
  (interactive (list (get-text-property (point) 'dnel-notification)))
  (unless (and notification (dnel-notification-pop-suffix notification))
    (user-error "No active notification at point"))
  (dnel--close-notification notification 2))

(defun dnel-toggle-body-visibility (position)
  "Toggle visibility of the body of notification at POSITION."
  (interactive "d")
  (let ((prop 'dnel-notification))
    (unless (or (get-text-property position prop)
                (if (> position 1) (get-text-property (cl-decf position) prop)))
      (user-error "No notification at or before position"))
    (let* ((end (or (next-single-property-change position prop) (point-max)))
           (begin (or (previous-single-property-change end prop) (point-min)))
           (eol (save-excursion (goto-char begin) (line-end-position)))
           (current (get-text-property eol 'invisible))
           (inhibit-read-only t))
      (if (< eol end) (put-text-property eol end 'invisible (not current))))))

(defun dnel--close-notification-by-id (id)
  "Close the notification identified by ID."
  (let ((found (cl-find id (cdr dnel--state)
                        :test #'eq :key #'dnel-notification-id)))
    (if found (dnel--close-notification found 3) (signal 'dbus-error nil)))
  :ignore)

(defun dnel--close-notification (notification reason)
  "Close the NOTIFICATION for REASON."
  (dnel--delete-notification notification)
  (run-hook-with-args 'dnel-notifications-changed-functions notification nil)
  (dnel--dbus-talk-to (dnel-notification-client notification) 'dbus-send-signal
                      "NotificationClosed" (dnel-notification-id notification)
                      reason))

(defun dnel-format-notification (notification)
  "Return propertized description of NOTIFICATION."
  (let* ((hints (dnel-notification-hints notification))
         (urgency (or (dnel--get-hint hints "urgency") 1))
         (inherit (if (<= urgency 0) 'shadow (if (>= urgency 2) 'bold))))
    (format (propertize " %s[%s: %s]%s" 'face (list :inherit inherit)
                        'dnel-notification notification)
            (propertize " " 'display (dnel-notification-image notification))
            (dnel-notification-app-name notification)
            (dnel--format-summary notification)
            (propertize (concat "\n" (dnel-notification-body notification) "\n")
                        'invisible t))))

(defun dnel--format-summary (notification)
  "Return propertized summary of NOTIFICATION."
  (let ((summary (dnel-notification-summary notification))
        (controls `((mouse-1 . ,(lambda () (interactive)
                                  (dnel-invoke-action notification)))
                    (C-mouse-1 . ,(lambda () (interactive)
                                    (dnel-pop-to-log-buffer notification)))
                    (down-mouse-2 . ,(dnel--get-actions-keymap notification))
                    (mouse-3 . ,(lambda () (interactive)
                                  (dnel-dismiss-notification notification))))))
    (propertize summary 'mouse-face 'mode-line-highlight 'keymap
                `(keymap (header-line keymap . ,controls)
                         (mode-line keymap . ,controls) . ,controls))))

(defun dnel--get-actions-keymap (notification)
  "Return keymap for actions of NOTIFICATION."
  (cl-loop with in = (dnel-notification-actions notification) and out for i by 1
           while in do (push (let ((key (pop in)))
                               (list i 'menu-item (pop in)
                                     (lambda () (interactive)
                                       (dnel-invoke-action notification key))))
                             out)
           finally return (cons 'keymap (nreverse (cons "Actions" out)))))

(defun dnel--start-server ()
  "Register server to keep track of notifications in `dnel--state'."
  (dolist (args `(("Notify" ,#'dnel--notify t)
                  ("CloseNotification" ,#'dnel--close-notification-by-id t)
                  ("GetServerInformation"
                   ,(lambda () (list "DNel" "sinic" "0.1" "1.2")) t)
                  ("GetCapabilities" ,(lambda () '(("body" "actions"))) t)))
    (apply #'dnel--dbus-talk 'dbus-register-method args))
  (dbus-register-service :session dnel--service))

(defun dnel--stop-server ()
  "Dismiss all notifications, then unregister server."
  (mapc #'dnel-dismiss-notification (cdr dnel--state))
  (dbus-unregister-service :session dnel--service))

(defun dnel--notify (app-name replaces-id app-icon summary body actions
                              hints expire-timeout)
  "Handle call by introducing a new notification and return its ID.

APP-NAME, REPLACES-ID, APP-ICON, SUMMARY, BODY, ACTIONS, HINTS, EXPIRE-TIMEOUT
are the received values as described in the Desktop Notification standard."
  (let* ((old (if (> replaces-id 0)
                  (cl-find replaces-id (cdr dnel--state)
                           :test #'eq :key #'dnel-notification-id)))
         (new (dnel--notification-create
               :id (if old replaces-id (cl-incf (car dnel--state)))
               :app-name app-name :summary summary :body body :actions actions
               :image (dnel--get-image hints app-icon) :hints hints
               :client (dbus-event-service-name last-input-event))))
    (if (> expire-timeout 0)
        (setf (dnel-notification-timer new)
              (run-at-time (/ expire-timeout 1000.0) nil
                           #'dnel--close-notification new 1)))
    (if old (dnel--delete-notification old))
    (dnel--push-notification new)
    (run-hook-with-args 'dnel-notifications-changed-functions old new)
    (dnel-notification-id new)))

(defun dnel--get-image (hints app-icon)
  "Return image descriptor created from HINTS or from APP-ICON.

This function is destructive."
  (let ((image (or (dnel--data-to-image (dnel--get-hint hints "image-data" t))
                   (dnel--path-to-image (dnel--get-hint hints "image-path" t))
                   (dnel--path-to-image app-icon)
                   (dnel--data-to-image (dnel--get-hint hints "icon_data" t)))))
    (if image (setf (image-property image :max-height) (line-pixel-height)
                    (image-property image :ascent) 90))
    image))

(defun dnel--get-hint (hints key &optional remove)
  "Return and delete from HINTS the value specified by KEY.

The returned value is removed from HINTS if REMOVE is non-nil."
  (let* ((pair (assoc key hints))
         (tail (cdr pair)))
    (if (and remove pair) (setcdr pair nil))
    (caar tail)))

(defun dnel--path-to-image (image-path)
  "Return image descriptor created from file URI IMAGE-PATH."
  (let ((prefix "file://"))
    (if (and (stringp image-path) (> (length image-path) (length prefix))
             (string-equal (substring image-path 0 (length prefix)) prefix))
        (create-image (substring image-path (length prefix))))))

(defun dnel--data-to-image (image-data)
  "Return image descriptor created from raw (iiibiiay) IMAGE-DATA.

This function is destructive."
  (if image-data
      (cl-destructuring-bind (width height row-stride _ bit-depth channels data)
          image-data
        (when (and (= bit-depth 8) (<= 3 channels 4))
          (dnel--delete-padding data (* channels width) row-stride)
          (dnel--delete-padding data 3 channels)
          (let ((header (format "P6\n%d %d\n255\n" width height)))
            (create-image (apply #'unibyte-string (append header data))
                          'pbm t))))))

(defun dnel--delete-padding (list payload total)
  "Delete LIST elements between multiples of PAYLOAD and TOTAL.

This function is destructive."
  (if (< payload total)
      (let ((cell (cons nil list))
            (delete (if (and (= payload 3) (= total 4)) #'cddr  ; fast opcode
                      (apply-partially #'nthcdr (- total payload -1))))
            (keep (if (= payload 3) #'cdddr (apply-partially #'nthcdr payload))))
        (while (cdr cell)
          (setcdr (setq cell (funcall keep cell)) (funcall delete cell))))))

(defun dnel--push-notification (notification)
  "Push NOTIFICATION to parent state `dnel--state'."
  (let ((state dnel--state))
    (setf (dnel-notification-pop-suffix notification) state)
    (let ((next (cadr state)))
      (push notification (cdr state))
      (if next (setf (dnel-notification-pop-suffix next) (cdr state))))))

(defun dnel--delete-notification (notification)
  "Delete NOTIFICATION from parent state and return it."
  (let ((suffix (dnel-notification-pop-suffix notification)))
    (setf (dnel-notification-pop-suffix notification) nil)
    (let ((timer (dnel-notification-timer notification)))
      (if timer (cancel-timer timer)))
    (let ((next (caddr suffix)))
      (if next (setf (dnel-notification-pop-suffix next) suffix)))
    (pop (cdr suffix))))

(defun dnel--dbus-talk-to (service symbol &rest rest)
  "Help with most actions involving D-Bus service SERVICE.

If SERVICE is nil, then a service name is derived from `last-input-event'.

SYMBOL describes a D-Bus function (e.g., `dbus-call-method'),
REST contains the remaining arguments to that function."
  (apply symbol :session (or service (dbus-event-service-name last-input-event))
         dnel--path dnel--interface rest))

(defun dnel--dbus-talk (symbol &rest rest)
  "Help with most actions involving D-Bus service `dnel--service'.

SYMBOL describes a D-Bus function (e.g., `dbus-call-method'),
REST contains the remaining arguments to that function."
  (apply #'dnel--dbus-talk-to dnel--service symbol rest))

(defmacro dnel--with-log-buffer (&optional buffer &rest body)
  "Execute BODY with log BUFFER or with a newly initialized one."
  (declare (indent 1))
  `(with-current-buffer (or ,buffer (generate-new-buffer dnel--log-name))
     (let ((inhibit-read-only t))
       (unless ,buffer
         (special-mode)
         (use-local-map dnel-log-map)
         (save-excursion
           (dolist (notification (reverse (cdr dnel--state)))
             (setf (dnel-notification-log-position notification) (point))
             (insert (dnel-format-notification notification) ?\n))))
       ,@body)))

(defun dnel--update-log-buffer (old new)
  "Remove OLD notification from and add NEW one to log buffer."
  (let ((buffer (get-buffer dnel--log-name)))
    (dnel--with-log-buffer buffer
      (if buffer (save-excursion (dnel--update-log old new))))))

(defun dnel-pop-to-log-buffer (&optional notification)
  "Pop to log buffer and (optionally) move point to NOTIFICATION."
  (let ((buffer (get-buffer dnel--log-name))
        (position (if notification
                      (dnel-notification-log-position notification))))
    (dnel--with-log-buffer buffer
      (pop-to-buffer (current-buffer))
      (if position (dnel-toggle-body-visibility (goto-char position))))))

(defun dnel--update-log (old new)
  "Remove OLD notification from and add NEW one to current buffer."
  (if old (add-text-properties (goto-char (dnel-notification-log-position old))
                               (line-end-position) '(face (:strike-through t))))
  (when new
    (setf (dnel-notification-log-position new) (goto-char (point-max)))
    (insert (dnel-format-notification new) ?\n)))

(provide 'dnel)
;;; dnel.el ends here

(defpackage #:slynk-slepper
  (:use :cl #:slynk-api)
  (:export
   #:slepper))

(in-package #:slynk-slepper)

(defun mnesic-macroexpand-all (form ht-1)
  (let (stack (expansion-positions (make-hash-table)))
    (values
     (agnostic-lizard:walk-form
      form nil
      :on-every-form-pre
      (lambda (subform env)
        (declare (ignore env))
        (push (list :original subform
                    :at (gethash subform ht-1))
              stack)
        subform)
      :on-every-form
      (lambda (expansion env)
        (declare (ignore env))
        (setf (gethash expansion expansion-positions)
              (pop stack))
        expansion))
     expansion-positions)))

(defun containsp (a b)
  "True iff A contains B."
  (and (< (car a) (car b)) (> (cdr a) (cdr b))))

(defun forms-of-interest (expanded ht-2 debugp)
  (let ((interesting (make-hash-table)))
    (labels
        ((butdoc (forms)
           (member-if-not #'stringp forms))
         (butdeclares (forms)
           (member-if-not (lambda (form)
                            (and (consp form)
                                 (eq 'declare (first form))))
                          forms))
         (explore-definition (definition)
           (destructuring-bind (name arglist &rest body)
               definition
             (declare (ignore name arglist))
             (explore-body body)))
         (explore-body (forms)
           (mapc #'explore (butdeclares (butdoc forms))))
         (collect (form original loc)
           (setf (gethash loc interesting)
                 (list* :source loc
                        (and debugp
                             (list :form form
                                   :original original)))))
         (maybe-explore-atom (form safe-range)
           "Deem FORM's manifestations interesting if within SAFE-RANGE."
           (when (and (atom form)
                      form
                      (not (stringp form))
                      (not (keywordp form)))
             (loop with entry = (gethash form ht-2)
                   with original = (getf entry :original)
                   for loc in (getf entry :at)
                   when (containsp safe-range loc)
                     do (collect form original loc))))
         (explore (form)
           "Called when FORM is deemed interesting."
           (when (consp form)
             (let* ((entry (gethash form ht-2))
                    (loc (first (getf entry :at))))
               (when loc (collect form (getf entry :original) loc))
               (slynk-api:destructure-case
                   form
                 ((block name &rest body)
                  (declare (ignore name))
                  (mapc #'explore (butdeclares body)))
                 ((return-from name &optional value)
                  (declare (ignore name))
                  (explore value))
                 ((catch tag &rest body)
                  (explore tag)
                  (mapc #'explore body))
                 ((load-time-value form &optional read-only-p)
                  (declare (ignore form read-only-p)))
                 ((setq &rest things)
                  (loop for (nil val) on things by #'cddr
                        do (explore val)))
                 ((eval-when syms &rest body)
                  (when (member :execute syms)
                    (explore-body body)))
                 ((locally &rest body)
                  (explore-body body))
                 ((symbol-macrolet macrobindings &rest body)
                  (declare (ignore macrobindings))
                  (explore-body body))
                 ((flet definitions &rest body)
                  (mapc #'explore-definition definitions)
                  (explore-body body))
                 ((macrolet definitions &rest body)
                  (declare (ignore definitions))
                  (explore-body body))
                 ((tagbody &rest statements)
                  (mapc #'explore (remove-if #'atom statements)))
                 ((function thing)
                  (explore thing))
                 ((multiple-value-call function &rest arguments)
                  (explore function)
                  (mapc #'explore arguments))
                 ((the value-type form)
                  (declare (ignore value-type))  (explore form))
                 ((go tag) (declare (ignore tag)))
                 ((multiple-value-prog1 values-form &rest body)
                  (explore values-form)
                  (explore-body body))
                 ((throw tag result)
                  (explore tag) (explore result))
                 ((if test then &optional else)
                  (explore test) (explore then) (when else (explore else)))
                 ((progn &rest forms)
                  (mapc #'explore forms))
                 ((unwind-protect protected &rest cleanup)
                  (explore protected) (mapc #'explore cleanup))
                 ((labels definitions &rest body)
                  (explore-body body)
                  (mapc #'explore-definition definitions))
                 ((progv vars vals &rest body)
                  (explore vars)
                  (explore vals)
                  (explore-body body))
                 ((let* bindings &rest body)
                  (mapc #'explore
                        (mapcar #'second
                                (remove-if-not #'consp bindings)))
                  (explore-body body))
                 ((let bindings &rest body)
                  (mapc #'explore
                        (mapcar #'second
                                (remove-if-not #'consp bindings)))
                  (explore-body body))
                 ((quote thing)
                  (declare (ignore thing)))
               ;;; Quirks section
                 ;;
                 ;; * even though LABMDA is a macro, it expands to
                 ;; (function (lambda ..)) i.e. to itself, so we must
                 ;; handle it explicitly.
                 ((lambda arglist &rest body)
                  (declare (ignore arglist))
                  (explore-body body))
                 ;; * AGNOSTIC-LIZARD will refuse the expand the
                 ;; following by default (probably for good reason) so
                 ;; just add them here.
                 ((defun name arglist &rest body)
                  (declare (ignore name arglist))
                  (explore-body body))
                 ((defmethod name arglist &rest body)
                  (declare (ignore name arglist))
                  (explore-body body))
                 ((defmacro name arglist &rest body)
                  (declare (ignore name arglist))
                  (explore-body body))
                 ((cond &rest clauses)
                  (mapc #'explore (mapcar #'first clauses))
                  (mapc #'explore (mapcar #'second clauses)))
                 ((multiple-value-bind spec val &rest body)
                  (declare (ignore spec))
                  (explore val)
                  (explore-body body))
                 ((handler-bind bindings &rest body)
                  (mapc #'explore (mapcar #'second bindings))
                  (explore-body body))
                 (t
                  (let ((op (first form)))
                    (assert (symbolp op) nil "Suprised by ~a" form)
                    (loop for f in (rest form)
                          when loc do (maybe-explore-atom f loc)
                          do (explore f)))))))))
      (explore expanded)
      (let (retval)
        (maphash (lambda (k v)
                   (declare (ignore k))
                   (push v retval))
                 interesting)
        retval))))

;; Entry point
(defslyfun slepper (&key (string "(loop for x from 1 repeat 10 collect x)")
                         debugp)
  "Return plists representing forms of interest inside STRING.
If DEBUGP return information about the actual forms."
  (with-input-from-string (stream string)
    (let* ((ht-1 (make-hash-table))
           (form-tree
             (source-tracking-reader:read-tracking-source
              stream nil
              nil nil
              (lambda (form start end)
                (push (cons start end) (gethash form ht-1))))))
      (multiple-value-bind (expanded ht-2)
          (mnesic-macroexpand-all form-tree ht-1)
        (forms-of-interest expanded ht-2 debugp)))))

(provide 'slynk-slepper)

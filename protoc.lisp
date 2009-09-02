;; Copyright 2009, Georgia Tech Research Corporation
;; All rights reserved.
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; * Redistributions of source code must retain the above copyright
;;   notice, this list of conditions and the following disclaimer.
;;
;; * Redistributions in binary form must reproduce the above copyright
;;   notice, this list of conditions and the following disclaimer in
;;   the documentation and/or other materials provided with the
;;   distribution.
;;
;; * Neither the name of the copyright holder(s) nor the names of its
;;   contributors may be used to endorse or promote products derived
;;   from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
;; FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
;; COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
;; INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
;; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
;; HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
;; STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
;; OF THE POSSIBILITY OF SUCH DAMAGE.


;; Protocol Buffer Compiler for CL
;; Author: Neil T. Dantam



(defpackage :protocol-buffer-compiler
  (:nicknames :protoc)
  (:use :cl))

(in-package :protocol-buffer-compiler)

(defparameter *message-plist-sym* 'message)

(defun lisp-type (ident &optional repeated)
  (let ((base (case ident
                ((:int32 :sfixed32 :sint32) '(cl:signed-byte 32))
                ((:uint32 :fixed32) '(cl:unsigned-byte 32))
                ((:int64 :sfixed64 :sint64) '(cl:signed-byte 64))
                ((:uint64 :fixed64) '(cl:unsigned-byte 64))
                ((:bool) 'cl:t)
                (:double 'cl:double-float)
                (:string 'cl:string)
                (:float 'cl:single-float))))
    (if repeated 
        `(array ,base *)
        base)))



(defun mangle-upcase-hypen (ident)
  (with-output-to-string (s)
    (let* ((str (string ident))
           (uncamel (find-if #'lower-case-p str)))
      (princ (char-upcase (aref str 0)) s)
      (loop for c across (subseq str 1)
         do (cond 
              ((and uncamel (upper-case-p c))
               (princ #\- s)
               (princ  c s))
              ((lower-case-p c)
               (princ (char-upcase c) s))
              ((eq c #\_)
               (princ #\- s))
              (t
               (princ c s)))))))
                               

(defun pb-str (name)
  (mangle-upcase-hypen name))

(defun pb-sym (name &optional package)
  (if package
      (intern (pb-str name) 
              package))
      (intern (pb-str name) ))

(defun declare-message (raw-form &optional (package *package*))
  (destructuring-bind (message name &rest specs) raw-form
    (let ((msg-name-sym (pb-sym name package)))
      (setf (get msg-name-sym *message-plist-sym*)
            `(,message ,(pb-sym name package)
                      ,@(loop for spec in specs
                           collect 
                             (destructuring-bind (field name type &rest keys)
                                 spec
                               `(,field ,(pb-sym name package) 
                                       ,type ,@keys)))))
      msg-name-sym)))


(defun symbol-string= (a b)
  (string= (string a) (string b)))


(defun make-start-code-sym (slot-position type)
  (pb::make-start-code slot-position (pb::wire-typecode type)))

;(defun slot-default-value (type repeated default)
  ;(cond
    ;(default default)
    ;(repeated (make-array 0 :elment-type

(defun gen-pack1 (bufsym startsym valsym type)
  (case type
    ((:int32 :uint32 :uint64 :enum)
     `(incf ,startsym 
             (binio:encode-uvarint ,valsym ,bufsym ,startsym)))
    ((:sint32 :sint64)
     `(incf ,startsym 
             (binio:encode-svarint ,valsym ,bufsym ,startsym)))
    ((:fixed32 :sfixed32)
     `(incf ,startsym 
             (binio:encode-int ,valsym :little ,startsym 32)))
    ((:fixed64 :sfixed64)
     `(incf ,startsym 
            (binio:encode-int ,valsym :little ,startsym 64)))
    (:string
     (let ((strbuf (gensym))
           (size (gensym)))
       `(multiple-value-bind (,size ,strbuf)
            (binio::encode-utf8 ,valsym)
          (incf ,startsym 
                (binio:encode-uvarint ,size ,bufsym ,startsym))
          (replace ,bufsym ,strbuf :start1 ,startsym)
          (incf ,startsym  ,size))))))


(defun gen-start-code-size (type pos)
  (binio::uvarint-size (make-start-code-sym pos type)))

(defun gen-scalar-size (type slot pos)
  `(+ ,(gen-start-code-size type pos)
      ,(cond 
        ((pb::fixed64-p type) 8)
        ((pb::fixed32-p type) 4)
        ((pb::uvarint-p type) 
         `(binio::uvarint-size ,slot))
        ((pb::svarint-p type) 
         `(pb::uvarint-size ,slot))
        ((eq :string type)
         `(pb::length-delim-size (binio::utf8-size ,slot)))
        ((eq :bytes type)
         `(pb::length-delim-size (length ,slot)))
        (t `(pb::length-delim-size (pb::packed-size ,slot))))))

(defun gen-repeated-size (type slot pos)
  (cond 
    ((pb::fixed-p type) 
     `(* (length ,slot)
         (+ ,(gen-start-code-size type pos) 
            ,(pb::fixed-size type) (length ,slot))))
    (t 
     (let ((i (gensym))
           (accum (gensym)))
       `(let ((,accum 0))
          (dotimes (,i (length ,slot))
            ,(gen-scalar-size type `(aref ,slot ,i) pos))
          ,accum)))))

        ;((pb::svarint-p type) 
         ;`(pb::packed-uvarint-size ,slot))
        ;(t `(pb::packed-size ,slot))

(defun gen-packed-size (type slot &optional pos)
  (let ((array-size 
         (cond 
           ((pb::fixed64-p type) `(* 8 (length ,slot)))
           ((pb::fixed32-p type) `(* 4 (length ,slot)))
           ((pb::uvarint-p type) 
            `(pb::packed-uvarint-size ,slot))
           ((pb::svarint-p type) 
            `(pb::packed-uvarint-size ,slot))
           (t (error "Can't pack this type")))))
    (if pos
        `(+ ,(gen-start-code-size :bytes pos) 
            (pb::length-delim-size ,array-size))
        array-size)))

(defun gen-slot-size (type objsym slot-name pos packed repeated)
  (let ((slot `(slot-value ,objsym ',slot-name)))
    (cond
      ((not repeated)
       (gen-scalar-size type slot pos))
      ((not packed)
       (gen-repeated-size type slot pos))
      (packed
       (gen-packed-size type slot pos)))))

  
(defun def-packed-size (form package)
  (destructuring-bind (message name &rest field-specs) form
    (assert (symbol-string= message 'message) () "Not a message form")
    (let ((protobuf (pb-sym 'protobuf package)))
      `(defmethod pb::packed-size ((,protobuf ,(pb-sym name package)))
         (+ ,@(mapcan (lambda (field-spec)
                        (when (symbol-string= (car field-spec) "FIELD")
                          (destructuring-bind (field name type position 
                                                     &key 
                                                     (default nil)
                                                     (required nil)
                                                     (repeated nil)
                                                     (optional nil)
                                                     (packed nil))
                              field-spec
                            (declare (ignore field default required optional))
                            (list (gen-slot-size type protobuf  name position 
                                                 packed repeated))
                            )))
                      field-specs))
         ))))
 
         
(defun gen-pack-slot (bufsym startsym objsym name pos type repeated packed)
  (let ((slot `(slot-value ,objsym ',name)))
    (cond 
      ;; scalar value
      ((null repeated)
       `( ;; write start code
         (incf ,startsym 
               (pb::encode-start-code ,pos 
                                      ,(pb::wire-typecode type)
                                      ,bufsym ,startsym))

         ;; write data code
         ,(gen-pack1 bufsym startsym slot type)))
      ;; repeated unpacked value
      ((and repeated (not packed))
       (let ((countsym (gensym)))
         `((dotimes (,countsym ,(length slot)) ; n times
             ;; write start code
             (incf ,startsym 
                   (pb::encode-start-code ,pos 
                                          ,(pb::wire-typecode type)
                                          ,bufsym ,startsym))
             ;; write element
             ,(gen-pack1 bufsym startsym  `(aref ,slot ,countsym) type)))))
      ;; repeated value
      ((and repeated packed)
       `( ;; write start code
         (incf ,startsym 
               (pb::encode-start-code ,pos 
                                      ,(pb::wire-typecode :bytes)
                                      ,bufsym ,startsym))
         ;; write length
         ,(gen-pack1 bufsym startsym 
                     (gen-packed-size type slot) :uint64)
         ;; write elements
         ,(let ((isym (gensym)))
               `(dotimes (,isym (length ,slot))
                  ,(gen-pack1 bufsym startsym 
                              `(aref ,slot ,isym) type))))))))
         

(defun msg-defpack (form package)
  (destructuring-bind (message name &rest field-specs) form
    (assert (symbol-string= message 'message) () "Not a message form")
    (let ((protobuf (pb-sym 'protobuf package))
          (buffer (pb-sym 'buffer package))
          (start (pb-sym 'start package))
          (i (gensym)))
      `(defmethod pb:pack ((,protobuf ,(pb-sym name package))
                           &optional
                           (,buffer (binio::make-octet-vector 
                                     (pb::packed-size ,protobuf)))
                           (,start 0))
         (let ((,i ,start))
           ,@(mapcan (lambda (field-spec)
                       (when (symbol-string= (car field-spec) "FIELD")
                         (destructuring-bind (field name type position 
                                                    &key 
                                                    (default nil)
                                                    (required nil)
                                                    (repeated nil)
                                                    (optional nil)
                                                    (packed nil))
                             field-spec
                           (declare (ignore field default required optional))
                           (gen-pack-slot buffer i protobuf 
                                          name position type repeated packed)
                           )))
                        field-specs)
           (values (- ,i ,start) ,buffer))))))
  

(defun msg-defclass (form package)
  (destructuring-bind (message name &rest field-specs) form
    (assert (symbol-string= message 'message) () "Not a message form")
    `(cl:defclass ,(pb-sym name package) ()
       ;; slots
       ,(mapcan (lambda (field-spec)
                  (when (symbol-string= (car field-spec) "FIELD")
                    (destructuring-bind (field name type position 
                                               &key 
                                               (default nil)
                                               (required nil)
                                               (repeated nil)
                                               (packed nil)
                                               (optional nil))
                        field-spec
                      (declare (ignore position field packed default required optional))
                      `((,name 
                         :type ,(lisp-type type repeated))))))
                field-specs))))



(defun load-proto-se (path &optional (package (find-package :cl-user)))
  (with-open-file (stream path)
    (loop 
       for form = (read stream nil)
       until (null form)
       do
         (format t "~S~%" form)
         collect
         (cond 
           ((symbol-string= (car form) "MESSAGE")
            (format t "Declareing: ~&~S~%" form)
            (declare-message form package))
           (t (error "Unknown form in proto file: ~A" (car form)))))))


(defun eval-proto (form &optional (package *package*))
  (eval 
   `(progn
      ,(msg-defclass form package)
      ,(def-packed-size form package)
      ,(msg-defpack form package))))
  

(defmacro compile-proto (name &optional (package *package*))
  (let ((form (get name 'message)))
    `(progn
       ,(msg-defclass form package)
       ,(def-packed-size form package)
       ,(msg-defpack form package))))
       

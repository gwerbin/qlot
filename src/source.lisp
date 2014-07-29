(in-package :cl-user)
(defpackage qlot.source
  (:use :cl)
  (:import-from :qlot.tmp
                :tmp-path)
  (:import-from :qlot.util
                :with-package-functions)
  (:import-from :fad
                :list-directory
                :pathname-absolute-p)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :digest-file
                :digest-sequence)
  (:import-from :flexi-streams
                :with-output-to-sequence)
  (:import-from :alexandria
                :copy-stream)
  (:export :*dist-base-url*
           :source
           :make-source
           :find-source-class
           :initialize
           :project-name
           :version
           :source-project-name
           :source-version
           :source-dist-name
           :source-initialized
           :project.txt
           :distinfo.txt
           :releases.txt
           :systems.txt
           :archive
           :url-path-for
           :install-source

           :source-has-directory
           :source-directory
           :source-archive))
(in-package :qlot.source)

(defvar *dist-base-url* nil)

(defclass source ()
  ((project-name :initarg :project-name
                 :reader source-project-name)
   (version :initarg :version
            :accessor source-version)
   (initialized :initform nil
                :accessor source-initialized)))

(defgeneric make-source (source &rest args))

(defun find-source-class (class-name)
  (intern (format nil "~A-~:@(~A~)" #.(string :source) class-name)
          (format nil "~A.~:@(~A~)" #.(string :qlot.source) class-name)))

(defgeneric source-dist-name (source)
  (:method ((source source))
    (source-project-name source)))

(defmethod print-object ((source source) stream)
  (format stream "#<~S ~A ~A>"
          (type-of source)
          (source-project-name source)
          (source-version source)))

(defgeneric initialize (source)
  (:method ((source source))))
(defmethod initialize :around (source)
  (if (source-initialized source)
      t
      (call-next-method)))
(defmethod initialize :after (source)
  (setf (source-initialized source) t))

(defgeneric install-source (source)
  (:method (source)))


;;
;; Pages

(defgeneric project.txt (source)
  (:method ((source source))
    (format nil "name: ~A
version: ~A
distinfo-subscription-url: ~A~A
release-index-url: ~A~A
system-index-url: ~A~A
"
            (source-dist-name source)
            (source-version source)
            *dist-base-url* (url-path-for source 'project.txt)
            *dist-base-url* (url-path-for source 'releases.txt)
            *dist-base-url* (url-path-for source 'systems.txt))))

(defgeneric distinfo.txt (source)
  (:method ((source source))
    (format nil "name: ~A
version: ~A
system-index-url: ~A~A
release-index-url: ~A~A
archive-base-url: ~A/
canonical-distinfo-url: ~A~A
distinfo-subscription-url: ~A~A
"
            (source-dist-name source)
            (source-version source)
            *dist-base-url* (url-path-for source 'systems.txt)
            *dist-base-url* (url-path-for source 'releases.txt)
            *dist-base-url*
            *dist-base-url* (url-path-for source 'distinfo.txt)
            *dist-base-url* (url-path-for source 'project.txt))))

(defgeneric releases.txt (source))
(defgeneric systems.txt (source))
(defgeneric archive (source))

(defgeneric url-path-for (source for)
  (:method (source (for (eql 'project.txt)))
    (format nil "/~A.txt" (source-project-name source)))
  (:method (source (for (eql 'distinfo.txt)))
    (format nil "/~A/~A/distinfo.txt"
            (source-project-name source)
            (source-version source)))
  (:method (source (for (eql 'systems.txt)))
    (format nil "/~A/~A/systems.txt"
            (source-project-name source)
            (source-version source)))
  (:method (source (for (eql 'releases.txt)))
    (format nil "/~A/~A/releases.txt"
            (source-project-name source)
            (source-version source)))
  (:method (source (for (eql 'archive)))
    nil))

(defclass source-has-directory (source)
  ((directory :initarg :directory
              :reader source-directory)
   (archive :initarg :archive
            :reader source-archive)))

(defmethod initialize :before ((source source-has-directory))
  (ensure-directories-exist (tmp-path (pathname (format nil "~(~A~)/repos/" (type-of source)))))
  (ensure-directories-exist (tmp-path (pathname (format nil "~(~A~)/archive/" (type-of source))))))

(defmethod (setf source-directory) (value (source source-has-directory))
  (setf (slot-value source 'directory)
        (if (fad:pathname-absolute-p value)
            value
            (tmp-path (pathname (format nil "~(~A~)/repos/" (type-of source)))
                      value))))

(defmethod (setf source-archive) (value (source source-has-directory))
  (setf (slot-value source 'archive)
        (if (fad:pathname-absolute-p value)
            value
            (tmp-path (pathname (format nil "~(~A~)/archive/" (type-of source)))
                      value))))

(defun source-systems (source)
  (check-type source source)
  (remove-if-not
   (lambda (path)
     (equal (pathname-type path) "asd"))
   (fad:list-directory (source-directory source))))

(defmethod systems.txt ((source source-has-directory))
  (with-output-to-string (s)
    (format s "# project system-file system-name [dependency1..dependencyN]~%")
    (let ((asdf:*central-registry* (cons (source-directory source)
                                         asdf:*central-registry*)))
      (dolist (system-file (source-systems source))
        (format s "~{~A~^ ~}~%"
                (list* (source-project-name source)
                       (file-namestring system-file)
                       (pathname-name system-file)
                       (mapcar #'string-downcase
                               (asdf::component-sideway-dependencies (asdf:find-system (pathname-name system-file))))))))))

(defmethod releases.txt ((source source-has-directory))
  (let ((version (source-version source))
        (tarball-file (source-archive source))
        (prefix (car (last (pathname-directory (source-directory source))))))
    (multiple-value-bind (size file-md5 content-sha1)
        (with-open-file (in tarball-file :element-type '(unsigned-byte 8))
          (values (file-length in)
                  (ironclad:byte-array-to-hex-string
                   (ironclad:digest-file :md5 tarball-file))
                  (ironclad:byte-array-to-hex-string
                   (ironclad:digest-sequence :sha1
                                             (flex:with-output-to-sequence (out)
                                               (alexandria:copy-stream in out :finish-output t))))))
      (with-slots (project-name) source
        (format nil "# project url size file-md5 content-sha1 prefix [system-file1..system-fileN]
~A ~A~A ~A ~A ~A ~A~{ ~A~}
"
                project-name
                *dist-base-url* (url-path-for source 'archive)
                size
                file-md5
                content-sha1
                prefix
                (mapcar #'file-namestring
                        (source-systems source)))))))

(defmethod archive ((source source-has-directory))
  (source-archive source))

(defmethod url-path-for ((source source-has-directory) (for (eql 'archive)))
  (format nil "/archive/~A/~A/~A"
          (source-project-name source)
          (source-version source)
          (file-namestring (archive source))))

(defmethod install-source ((source source-has-directory))
  (with-package-functions :ql-dist (provided-releases dist ensure-installed)
    (dolist (release (provided-releases (dist (source-dist-name source))))
      (ensure-installed release))))

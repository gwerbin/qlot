(defpackage #:qlot/utils/git
  (:use #:cl)
  (:import-from #:qlot/utils/shell
                #:safety-shell-command
                #:shell-command-error)
  (:import-from #:qlot/utils
                #:with-in-directory
                #:split-with)
  (:export #:git-clone
           #:create-git-tarball
           #:git-ref))
(in-package #:qlot/utils/git)

(defun git-clone (remote-url destination &key (checkout-to "master") ref)
  (tagbody git-cloning
    (when (uiop:directory-exists-p destination)
      (uiop:delete-directory-tree destination :validate t))
    (restart-case
        (safety-shell-command "git"
                              `("clone"
                                "--branch" ,checkout-to
                                "--depth" "1"
                                "--recursive"
                                "--config" "core.eol=lf"
                                "--config" "core.autocrlf=input"
                                ,remote-url
                                ,destination))
      (retry-git-clone ()
        :report "Retry to git clone the repository."
        (uiop:delete-directory-tree destination :validate t :if-does-not-exist :ignore)
        (go git-cloning))))

  (when ref
    (let ((*error-output* (make-broadcast-stream)))
      (with-in-directory destination
        (safety-shell-command "git" '("fetch" "--unshallow"))
        (safety-shell-command "git" `("checkout" ,ref))))))

(defun create-git-tarball (project-directory destination ref)
  (check-type project-directory pathname)
  (check-type destination pathname)
  (check-type ref string)
  (let* ((prefix (car (last (pathname-directory project-directory))))
         (tarball (merge-pathnames (format nil "~A.tar.gz" prefix) destination)))
    (with-in-directory project-directory
      (safety-shell-command "git"
                            `("archive" "--format=tar.gz" ,(format nil "--prefix=~A/" prefix)
                              ,ref
                              "-o" ,tarball)))
    tarball))

(defun git-ref (remote-url &optional (ref-identifier "HEAD"))
  (handler-case
      (let ((*standard-output* (make-broadcast-stream)))
        (first
          (split-with #\Tab
                      (safety-shell-command "git"
                                            (list "ls-remote"
                                                  remote-url
                                                  ref-identifier))
                      :limit 2)))
    (shell-command-error (e)
      (warn (princ-to-string e))
      (error "No git references named '~A'." ref-identifier))))

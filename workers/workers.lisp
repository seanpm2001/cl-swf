(in-package :swf-workers)

(declaim (optimize (speed 0) (debug 3) (safety 3) (space 0)))

;; TODO: Check for duplicate workflow and activties types in a worker

;;; Common worker ----------------------------------------------------------------------------------

(defclass task-type ()
  ((name :initarg :name :reader task-type-name)
   (options :initarg :options :reader task-type-options)
   (function :initarg :function :reader task-type-function)))

(defclass workflow-type (task-type) ())
(defclass activity-type (task-type) ())

(defgeneric ensure-task-type (task-type))

(defmethod ensure-task-type ((workflow-type workflow-type))
  (handler-case
      (apply #'swf::register-workflow-type (task-type-options workflow-type))
    (swf::type-already-exists-error ()
      ;; TODO check if options are equal
      )))

(defmethod ensure-task-type ((activity-type activity-type))
  (handler-case
      (apply #'swf::register-activity-type (task-type-options activity-type))
    (swf::type-already-exists-error ()
      ;; TODO check if options are equal
      )))


(defvar *worker*)


(defclass worker ()
  ((service :initarg :service
            :initform (swf::service)
            :reader worker-service)
   (task-list :initarg :task-list
              :initform "default"
              :reader worker-task-list)
   (packages :initarg :packages
             :initform (list *package*)
             :reader worker-packages)))


(defun worker-start (worker type)
  (loop (worker-handle-next-task worker type)))


(defun worker-start-thread (worker type)
  (sb-thread:make-thread (lambda (worker type)
                           (worker-start worker type))
                         :name (format nil "~S worker for ~S" type worker)
                         :arguments (list worker type)))


(defun worker-look-for-task (worker type)
  (let ((swf::*service* (worker-service worker)))
    (let ((identity (princ-to-string sb-thread:*current-thread*)))
      (ecase type
        (:workflow
         (let ((response (swf::poll-for-decision-task :all-pages t
                                                      :identity identity
                                                      :task-list (worker-task-list worker))))
           (when (aget response :events)
             response)))
        (:activity
           (let ((response (swf::poll-for-activity-task :identity identity
                                                        :task-list (worker-task-list worker))))
             (when (aget response :task-token)
               response)))))))


(defun worker-handle-next-task (worker type)
  (with-error-handling
    (with-simple-restart (carry-on "Stop handle-next-task.")
      (let ((task (worker-look-for-task worker type)))
        (when task
          (with-simple-restart (carry-on "Stop handling this ~A task." type)
            (worker-handle-task worker type task)))))))


(defun worker-handle-task (worker type task)
  (let ((*worker* worker)
        (swf::*service* (worker-service worker)))
    (restart-case
        (destructuring-bind (function &rest args)
            (ecase type
              (:workflow
               (worker-compute-workflow-response task))
              (:activity
               (worker-compute-activity-response task)))
          (apply function args))
      (retry ()
        :report "Retry handle task"
        (worker-handle-task worker type task))
      (terminate-workflow ()
        :report "Terminate this workflow exectuion and all child workflows."
        (swf::terminate-workflow-execution :child-policy :terminate
                                           :details "Terminated by restart."
                                           :run-id (aget task :workflow-execution :run-id)
                                           :workflow-id (aget task :workflow-execution :workflow-id))))))


(defun find-task-type-in-package (package type-spec)
  (let ((task-type (get (find-symbol (aget type-spec :name) package) 'task-type)))
    (when (and task-type
               (equal (aget type-spec :version) (getf (task-type-options task-type) :version)))
      task-type)))


(defun find-task-type (x)
  (etypecase x
    (symbol
     (get x 'task-type))
    (cons
     (some (lambda (package)
             (find-task-type-in-package package x))
           (worker-packages *worker*)))))


(defun worker-ensure-task-types (worker)
  (dolist (package (worker-packages worker))
    (do-symbols (symbol package)
      (let ((task-type (get symbol 'task-type)))
        (when task-type
          (ensure-task-type task-type))))))


(defun find-workflow-type (x)
  (let ((workflow-type (find-task-type x)))
    (when (typep workflow-type 'workflow-type)
      workflow-type)))


(defun find-activity-type (x)
  (let ((activity-type (find-task-type x)))
    (when (typep activity-type 'activity-type)
      activity-type)))


;;; Defining workflows ----------------------------------------------------------------------------


(defmacro define-workflow (name
                           (&rest workflow-args)
                              (&key (version :1)
                                    default-child-policy
                                    default-execution-start-to-close-timeout
                                    (default-task-list "default")
                                    default-task-start-to-close-timeout
                                    description)
                           &body body)
  (let ((decider-function (intern (format nil "%%~A" name)))
        (string-name (string name))
        (string-version (string version)))
    `(progn
       (defun ,name (&key ,@workflow-args
                       child-policy
                       execution-start-to-close-timeout
                       tag-list
                       task-list
                       task-start-to-close-timeout
                       workflow-id)
         (%start-workflow :child-policy child-policy
                          :execution-start-to-close-timeout execution-start-to-close-timeout
                          :input (list ,@(loop for arg in workflow-args
                                               collect (intern (symbol-name arg) :keyword)
                                               collect arg))
                          :tag-list tag-list
                          :task-list task-list
                          :task-start-to-close-timeout task-start-to-close-timeout
                          :workflow-id workflow-id
                          :workflow-type (alist :name ,string-name :version ,string-version)))
       (defun ,decider-function (&key ,@workflow-args)
         ,@body)
       (setf (get ',name 'task-type)
             (make-instance 'workflow-type
                            :name ',name
                            :function #',decider-function
                            :options (list :name ,string-name
                                           :version ,string-version
                                           :default-child-policy
                                           ,default-child-policy
                                           :default-execution-start-to-close-timeout
                                           ,default-execution-start-to-close-timeout
                                           :default-task-list
                                           ,default-task-list
                                           :default-task-start-to-close-timeout
                                           ,default-task-start-to-close-timeout
                                           :description ,description))))))


(defun %start-workflow (&key child-policy
                          execution-start-to-close-timeout
                          input
                          tag-list
                          task-list
                          task-start-to-close-timeout
                          workflow-id
                          workflow-type)
  (loop with input-string = (serialize-object input)
        for id-bits from 16 by 8
        for id = (or workflow-id
                     (format nil "~(~36R~)" (random (expt 2 id-bits))))
        do
        (handler-case
            (return
              (alist :workflow-id id
                     :run-id (swf::start-workflow-execution
                              :child-policy child-policy
                              :execution-start-to-close-timeout execution-start-to-close-timeout
                              :input input-string
                              :tag-list tag-list
                              :task-list task-list
                              :task-start-to-close-timeout task-start-to-close-timeout
                              :workflow-id id
                              :workflow-type workflow-type)))
          (swf::workflow-execution-already-started-error (err)
            (when workflow-id
              (error err))))))


;;; Defining activities ----------------------------------------------------------------------------


(defmacro define-activity (name
                           (&rest activity-args)
                              (&key (version :1)
                                    (default-task-heartbeat-timeout :none)
                                    (default-task-list "default")
                                    (default-task-schedule-to-close-timeout :none)
                                    (default-task-schedule-to-start-timeout :none)
                                    (default-task-start-to-close-timeout :none)
                                    description)
                           &body body)
  (let ((activity-function (intern (format nil "%%~A" name)))
        (string-name (string name))
        (string-version (string version)))
    `(progn
       (defun ,name (&key ,@activity-args
                       activity-id
                       control
                       heartbeat-timeout
                       schedule-to-close-timeout
                       schedule-to-start-timeout
                       start-to-close-timeout
                       task-list)
         (schedule-activity-task :activity-id activity-id
                                 :activity-type (alist :name ,string-name :version ,string-version)
                                 :control control
                                 :heartbeat-timeout heartbeat-timeout
                                 :input (list ,@(loop for arg in activity-args
                                                      collect (intern (symbol-name arg) :keyword)
                                                      collect arg))
                                 :schedule-to-close-timeout schedule-to-close-timeout
                                 :schedule-to-start-timeout schedule-to-start-timeout
                                 :start-to-close-timeout start-to-close-timeout
                                 :task-list task-list))
       (defun ,activity-function (&key ,@activity-args)
         ,@body)
       (setf (get ',name 'task-type)
             (make-instance 'activity-type
                            :name ',name
                            :function #',activity-function
                            :options (list :name ,string-name
                                           :version ,string-version
                                           :default-task-heartbeat-timeout
                                           ,default-task-heartbeat-timeout
                                           :default-task-list
                                           ',default-task-list
                                           :default-task-schedule-to-close-timeout
                                           ,default-task-schedule-to-close-timeout
                                           :default-task-schedule-to-start-timeout
                                           ,default-task-schedule-to-start-timeout
                                           :default-task-start-to-close-timeout
                                           ,default-task-start-to-close-timeout
                                           :description ,description))))))


;;; Handling workflow tasks ------------------------------------------------------------------------


(defun worker-compute-workflow-response (task)
  (list #'swf::respond-decision-task-completed
        :task-token (aget task :task-token)
        :decisions (run-decision-task task)))


(defun run-decision-task (task)
  (let* ((workflow-type (aget task :workflow-type))
         (workflow (or (find-workflow-type workflow-type)
                       (error "Could find workflow type ~S." workflow-type)))
         (decider-function (task-type-function workflow)))
    (let ((*wx* (make-workflow-execution-info (aget task :events)))
          (*decisions* nil))
      (apply decider-function (deserialize-object (event-input (get-event (task-started-event-id *wx*)))))
      (nreverse *decisions*))))


;;; Handling activity tasks ------------------------------------------------------------------------


(define-condition activity-error (error)
  ((reason :initarg :reason
           :reader activity-error-reason)
   (details :initarg :details
            :initform nil
            :reader activity-error-details)))


(defvar *default-activity-error-reason*)
(defvar *default-activity-error-details*)


(defun error-detail (key)
  (getf *default-activity-error-details* key))


(defun (setf error-detail) (value key)
  (if (error-detail key)
    (setf (getf *default-activity-error-details* key) value)
    (progn (push value *default-activity-error-details*)
           (push key *default-activity-error-details*)))
  value)


(defun worker-compute-activity-response (task)
  (handler-case
      (let ((*default-activity-error-reason* :error)
            (*default-activity-error-details* nil))
        (let (error)
          (restart-case
              (handler-bind ((error (lambda (e) (setf error e))))
                (let ((value (compute-activity-task-value task)))
                  (list #'swf::respond-activity-task-completed
                        :result (serialize-object value)
                        :task-token (aget task :task-token))))
            (carry-on ()
              :report "Fail activity"
              (error 'activity-error
                     :reason *default-activity-error-reason*
                     :details (list* :condition (format nil "~A" error)
                                     *default-activity-error-details*))))))
    (activity-error (error)
      (list #'swf::respond-activity-task-failed
            :task-token (aget task :task-token)
            :reason (serialize-object (activity-error-reason error))
            :details (serialize-object (activity-error-details error))))))


(defun read-new-value ()
  (format t "Enter a new value: ")
  (eval (read)))


(defun compute-activity-task-value (task)
  (restart-case
      (let* ((activity-type (aget task :activity-type))
             (activity (or (find-activity-type activity-type)
                           (error "Could not find activity type ~S." activity-type)))
             (input (deserialize-object (aget task :input))))
        (apply (task-type-function activity) input))
    (use-value (&rest new-value)
      :report "Return something else."
      :interactive read-new-value
      new-value)))

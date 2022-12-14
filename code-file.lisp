(ql:quickload "clx")
(ql:quickload "zpng")
(ql:quickload "png-read")
(ql:quickload "local-time")

(defmacro with-display (host (display screen root-window) &body body)
  `(let* ((,display (xlib:open-display ,host))
          (,screen (first (xlib:display-roots ,display)))
          (,root-window (xlib:screen-root ,screen)))
     (unwind-protect (progn ,@body)
       (xlib:close-display ,display))))

(defmacro with-default-display ((display &key (force nil)) &body body)
  `(let ((,display (xlib:open-default-display)))
     (unwind-protect
          (unwind-protect
               ,@body
            (when ,force
              (xlib:display-force-output ,display)))
       (xlib:close-display ,display))))

(defmacro with-default-display-force ((display) &body body)
  `(with-default-display (,display :force t) ,@body))

(defmacro with-default-screen ((screen) &body body)
  (let ((display (gensym)))
    `(with-default-display (,display)
       (let ((,screen (xlib:display-default-screen ,display)))
         ,@body))))

(defmacro with-default-window ((window) &body body)
  (let ((screen (gensym)))
    `(with-default-screen (,screen)
       (let ((,window (xlib:screen-root ,screen)))
         ,@body))))

(defun x-size ()
  (with-default-screen (s)
    (values
     (xlib:screen-width s)
     (xlib:screen-height s))))

(defparameter *default-x* 274)
(defparameter *default-y* 903)
(defparameter *default-width* (- 1842 903))
(defparameter *default-heght* (- 1070 274))

(defun raw-image->png (data width height)
  (let* ((png (make-instance 'zpng:png :width width :height height
                             :color-type :truecolor-alpha
                             :image-data data))
         (data (zpng:data-array png)))
    (dotimes (y height)
      (dotimes (x width)
        ;; BGR -> RGB, ref code: https://goo.gl/slubfW
        ;; diffs between RGB and BGR: https://goo.gl/si1Ft5
        (rotatef (aref data y x 0) (aref data y x 2))
        (setf (aref data y x 3) 255)))
    png))

(multiple-value-bind (default-width default-height) (x-size)
  (defun x-snapshot (&key (x *default-x*) (y *default-y*)
                       (width  *default-width*) (height *default-heght*)
                       path)
    ;; "Return RGB data array (The dimensions correspond to the height, width,
    ;; and pixel components, see comments in x-snapsearch for more details),
    ;; or write to file (PNG only), depend on if you provide the path keyword"
    (with-default-window (w)
      (let ((image
             (raw-image->png
              (xlib:get-raw-image w :x x :y y
                                  :width width :height height
                                  :format :z-pixmap)
              width height)))
        (if path
            (let* ((ext (pathname-type path))
                   (path
                    (if ext
                        path
                        (concatenate 'string path ".png")))
                   (png? (or (null ext) (equal ext "png"))))
              (cond
                (png? (zpng:write-png image path))
                (t (error "Only PNG file is supported"))))
            (zpng:data-array image))))))

;; ;; TEST: save screenshot
;; (x-snapshot :path "~/Pictures/snap1.png")


;; ????????????, ?????????????????????? ?????????? ???? ???????????????? ?????????????????? png
;; ?? ?????????????? ???????????????????? ?????????????? ???????? ???? ??????????
(define-condition unk-png-color-type (error)
  ((color :initarg :color :reader color))
  (:report
   (lambda (condition stream)
     (format stream "Error in LOAD-PNG: unknown color type: ~A"
             (color condition)))))

(defun load-png (pathname-str)
  "???????????????????? ???????????? size-X ???????????????? ???? size-Y ??????????,
   ?????? ?????????????? ???????? ??????????-??????????????, ?? ?????????? ?? ?????? - ????????????-????????
   ----
   ?? zpng ???????? ???????????????? ???? ?????????????????? ???????????????? COLOR:
   ----
         (defmethod samples-per-pixel (png)
           (ecase (color-type png)
             (:grayscale 1)
             (:truecolor 3)
             (:indexed-color 1)
             (:grayscale-alpha 2)
             (:truecolor-alpha 4)))
  "
  (let* ((png (png-read:read-png-file pathname-str))
         (image-data (png-read:image-data png))
         (color (png-read:colour-type png))
         (dims (cond ((or (equal color :truecolor-alpha)
                          (equal color :truecolor))
                      (list (array-dimension image-data 1)
                            (array-dimension image-data 0)
                            (array-dimension image-data 2)))
                     ((or (equal color :grayscale)
                          (equal color :greyscale))
                      (list (array-dimension image-data 1)
                            (array-dimension image-data 0)))
                     (t (error 'unk-png-color-type :color color))))
         (result ;; ???????????? ?????????????????????? X ?? Y ??????????????
          (make-array dims :element-type '(unsigned-byte 8))))
    ;; (format t "~% new-arr ~A "(array-dimensions result))
    ;; ????????????, ????????????, ???????? => ????????????, ????????????, ????????
    (macrolet ((cycle (&body body)
                 `(do ((y 0 (incf y)))
                      ((= y (array-dimension result 0)))
                    (do ((x 0 (incf x)))
                        ((= x (array-dimension result 1)))
                      ,@body))))
      (cond ((or (equal color :truecolor-alpha)
                 (equal color :truecolor))
             (cycle (do ((z 0 (incf z)))
                        ((= z (array-dimension result 2)))
                      (setf (aref result y x z)
                            (aref image-data x y z)))))
            ((or (equal color :grayscale)
                 (equal color :greyscale))
             (cycle (setf (aref result y x)
                          (aref image-data x y))))
            (t (error 'unk-png-color-type :color color)))
      result))
)
;; ;; TEST: equality screenshot and load-file-data
;; (assert (equalp (progn
;;                   (x-snapshot :path "~/Pictures/snap2.png")
;;                   (load-png "~/Pictures/snap2.png"))
;;                 (x-snapshot)))


(defun save-png (width height pathname-str image
                 &optional (color-type :truecolor-alpha))
  (let* ((png (make-instance 'zpng:png :width width :height height
                             :color-type color-type))
         (vector (make-array ;; displaced vector - need copy for save
                  (* height width (zpng:samples-per-pixel png))
                  :displaced-to image :element-type '(unsigned-byte 8))))
    ;; ?????? ???????????????? ???????????????????????? ?????????????? ????????, ?????????? ???? ??????????????
    ;; ???????????? PNG ?????? ????????????, ?? ?????????? ?????????????????? ?? ???????? ????????????,
    ;; ?????????????????? ???????????????????????????????? writer.
    ;; ?????? ?????????? ?????????? ???????????????? ???????????? ?????????????????????? ??????????????,
    ;; ?????????????? ???? ?????????? ???????????????? ?????? ???????????? ?? ?????? ????????
    ;; ???????????????? ???????????????? ?????? ?????????? ???????????????????? ??????????????
    (setf (zpng::%image-data png) (copy-seq vector))
    (zpng:write-png png pathname-str)))


;; ;; TEST: saving loaded data
;; (let* ((from "~/Pictures/snap2.png")
;;        (to   "~/Pictures/snap3.png")
;;        (image-data (load-png from)))
;;   (destructuring-bind (height width depth)
;;       (array-dimensions image-data)
;;     (save-png width height to image-data)))

;; ;; TEST: saving screenshot data
;; (let* ((to   "~/Pictures/snap4.png")
;;        (image-data (x-snapshot)))
;;   (destructuring-bind (height width depth)
;;       (array-dimensions image-data)
;;     (save-png width height to image-data)))


;; ???????????????????? ?????????????? ?????????????????????? ?? ??????????-??????????
(defun binarization (image &optional threshold)
  (let* ((dims (array-dimensions image))
         (new-dims (cond ((equal 3 (length dims))  (butlast dims))
                         ((equal 2 (length dims))  dims)
                         (t (error 'binarization-error))))
         (result (make-array new-dims :element-type '(unsigned-byte 8))))
    (macrolet ((cycle (&body body)
                 `(do ((y 0 (incf y)))
                      ((= y (array-dimension image 0)))
                    (do ((x 0 (incf x)))
                        ((= x (array-dimension image 1)))
                      ,@body))))
      (cond ((equal 3 (length dims))
             (cycle (do ((z 0 (incf z)))
                        ((= z (array-dimension image 2)))
                      (let ((avg (floor (+ (aref image y x 0)
                                           (aref image y x 1)
                                           (aref image y x 2))
                                        3)))
                        (when threshold
                          (if (< threshold avg)
                              (setf avg 255)
                              (setf avg 0)))
                        (setf (aref result y x) avg)))))
            ((equal 2 (length dims))
             (cycle (let ((avg (aref image y x)))
                      (when threshold
                        (if (< threshold avg)
                            (setf avg 255)
                            (setf avg 0)))
                      (setf (aref result y x) avg))))
            (t (error 'binarization-error))))
    result))

;; ;; TEST: load file and translate it to grayscale and save
;; (let* ((from "~/Pictures/snap4.png")
;;        (to   "~/Pictures/snap5.png")
;;        (image-data (binarization (load-png from))))
;;   (destructuring-bind (height width) ;; NB: no depth!
;;       (array-dimensions image-data)
;;     (save-png width height to image-data :grayscale))) ;; NB: grayscale!


;; ;; TEST: binarize and save screenshot
;; (let* ((to   "~/Pictures/snap6.png")
;;        (image-data (binarization (x-snapshot) 127))) ;; NEW: threshold!
;;   (destructuring-bind (height width) ;; NB: no depth!
;;       (array-dimensions image-data)
;;     (save-png width height to image-data :grayscale))) ;; NB: grayscale!

;; ;; TEST: try to load grayscale image and save it
;; (let* ((from "~/Pictures/snap6.png")
;;        (to   "~/Pictures/snap7.png")
;;        (image-data (load-png from)))
;;   (destructuring-bind (height width)
;;       (array-dimensions image-data)
;;     (save-png width height to image-data :grayscale)))

;; ;; TEST: try to load grayscale image, binarize and save it
;; (let* ((from "~/Pictures/snap7.png")
;;        (to   "~/Pictures/snap8.png")
;;        (image-data (binarization (load-png from) 127)))
;;   (destructuring-bind (height width) ;; NB: no depth!
;;       (array-dimensions image-data)
;;     (save-png width height to image-data :grayscale)))
(defun rectangle? (coordinates)
  (if (or (atom coordinates)
          (or (atom (car coordinates))
              (atom (cdr coordinates))))
      nil
      (let* ((down-left-x (caar coordinates))
             (down-left-y (cdar coordinates))
             (upper-right-x (caadr coordinates))
             (upper-right-y (cdadr coordinates))
             (hight (- upper-right-y down-left-y))
             (length (- upper-right-x down-left-x)))
        ;; ???? ?????????????? ?????????????????????????????? ???????????? ????????????, ?? ??????????????
        ;; ?????????? ?????????????????????? (?? 1.5) ?????????????????? ???????????? (???? ?????? ???????? ???? ????????????????
        ;; ???????????????????????????? ????????????)
        (and (> hight 0) (> length (* hight 1.5))))))

(defun test-rectangle?()
  (let ((test-line (list (cons 1 1) (cons 1 100)))
        (test-line2 (list (cons 1 1) (cons 100 1)))
        (test-square (list (cons 1 1) (cons 10 10)))
        (test-rectangle (list (cons 1 1) (cons 100 10))))
    (assert (equal (rectangle? test-line) nil))
    (assert (equal (rectangle? test-line2) nil))
    (assert (equal (rectangle? test-square) nil))
    (assert (equal (rectangle? (cons 1 2)) nil))
    (assert (equal (rectangle? '()) nil))
    (assert (equal (rectangle? nil) nil))
    (assert (equal (rectangle? test-rectangle) t))))

;; (test-rectangle?)


(defun bigger-rectangle? (coordinates1 coordinates2)
  (if (or (not (rectangle? coordinates1))
          (not (rectangle? coordinates2)))
      nil
      (let* ((down-left-x1 (caar coordinates1))
             (down-left-y1 (cdar coordinates1))
             (upper-right-x1 (caadr coordinates1))
             (upper-right-y1 (cdadr coordinates1))
             (down-left-x2 (caar coordinates2))
             (down-left-y2 (cdar coordinates2))
             (upper-right-x2 (caadr coordinates2))
             (upper-right-y2 (cdadr coordinates2))
             (hight1 (- upper-right-y1 down-left-y1))
             (length1 (- upper-right-x1 down-left-x1))
             (hight2 (- upper-right-y2 down-left-y2))
             (length2 (- upper-right-x2 down-left-x2)))
        (> (* hight1 length1) (* hight2 length2)))))

(defun test-bigger-rectangle?()
  (let ((test-rectangle-bigger (list (cons 1 1) (cons 100 10)))
        (test-rectangle-smaller (list (cons 1 1) (cons 50 10)))
        (test-line (list (cons 1 1) (cons 1 100)))
        (test-line2 (list (cons 1 1) (cons 100 1))))
    (assert (equal (bigger-rectangle? test-rectangle-bigger test-line) nil))
    (assert (equal (bigger-rectangle? test-rectangle-bigger test-line2) nil))
    (assert (equal (bigger-rectangle? test-rectangle-smaller test-rectangle-bigger) nil))
    (assert (equal (bigger-rectangle? test-rectangle-bigger test-rectangle-smaller) t))))

;; (test-bigger-rectangle?)
(defparameter *r-border* 12)
(defparameter *g-border* 30)
(defparameter *b-border* 54)

(defparameter *color-tolerance* 10)

(defun needed-pix? (x y r g b array-png)
  (let* ((max-array-y (- (array-dimension array-png 0) 1))
         (max-array-x (- (array-dimension array-png 1) 1))
         (if (or (< max-array-x x)
                 (< max-array-y y)
                 (< x 0)
                 (< y 0))
             nil
             (and (or (= r (aref image y x 0))
                      ( <= (abs (- r (aref image y x 0))) *color-tolerance*))
                  (or (= g (aref image y x 1))
                      ( <= (abs (- g (aref image y x 1))) *color-tolerance*))
                  (or (= b (aref image y x 2))
                      ( <= (abs (- b (aref image y x 2))) *color-tolerance*)))))))

(defun is-border? (x y max-y minimum-border-length array-png)
  (do ((y y (incf y))
       (border-length 0 (incf border-length)))
      ((or (= y (+ minimum-border-length y))
           (= y max-y)))
    (if (not (needed-pix? x y *r-border* *g-border* *b-border* array-png))
        (if (< border-length minimum-border-length)
            (return nil)
            (return t))))
  (< border-length minimum-border-length))

(defun find-border-coordinates(array-png)
  (let* ((max-array-y (- (array-dimension array-png 0) 1))
         (max-array-x (- (array-dimension array-png 1) 1))
         (minimum-border-length (* (floor (/ max-array-y 3))  2)))
    (dotimes (y max-array-y)
      (dotimes (x max-array-x)
        (if (needed-pix? x y *r-border* *g-border* *b-border* array-png)
            (if (is-border? x y max-array-y minimum-border-length array-png)
                (return (cons x y))))))))

(defun mklist (obj)
  (if (and
       (listp obj)
       (not (null obj)))
      obj (list obj)))

(defmacro defun-with-actions (name params actions &body body)
  "This macro defun a function which witch do mouse or keyboard actions,
body is called on each action."
  `(defun ,name ,params
     (mapcar
      #'(lambda (action)
          ,@body)
      (mklist ,actions))))

(defun x-move (x y)
  (if (and (integerp x) (integerp y))
      (with-default-display-force (d)
        (xlib/xtest:fake-motion-event d x y))
      (error "Integer only for position, (x: ~S, y: ~S)" x y)))

(defun perform-mouse-action (press? button &key x y)
  (and x y (x-move x y))
  (with-default-display-force (d)
    (xlib/xtest:fake-button-event d button press?)))

(macrolet ((def (name actions)
             `(defun-with-actions ,name
                  ;; ?? ???????? ???????? ?????????? ?????????????? ???????? - ?????? button 1
                  (&key (button 1) x y)
                  ,actions
                (funcall #'perform-mouse-action
                         action button :x x :y y))))
  (def x-mouse-down t)
  (def x-mouse-up nil)
  (def x-click '(t nil))
  (def x-dbclick '(t nil t nil)))

(defmacro with-scroll (pos neg clicks x y)
  `(let ((button (cond
                   ((= 0 ,clicks) nil)
                   ((> 0 ,clicks) ,pos) ; scroll up/right
                   ((< 0 ,clicks) ,neg)))) ; scroll down/left
     (dotimes (_ (abs ,clicks))
       (x-click :button button :x ,x :y ,y))))

(defun x-vscroll (clicks &key x y)
  (with-scroll 4 5 clicks x y))

(defun x-scroll (clicks &key x y)
  (x-vscroll clicks :x x :y y))

(defun x-hscroll (clicks &key x y)
  (with-scroll 7 6 clicks x y))

(defun perform-key-action (press? keycode) ; use xev to get keycode
  (with-default-display-force (d)
    (xlib/xtest:fake-key-event d keycode press?)))

(macrolet ((def (name actions)
             `(defun-with-actions ,name (keycode)
                  ,actions
                (funcall #'perform-key-action
                         action keycode))))
  (def x-key-down t)
  (def x-key-up nil)
  (def x-press '(t nil)))

;; ???????????????????? ???????????? ???????????????? ?? ????????
(defparameter *default-browser-x* 35)
(defparameter *default-browser-y* 75)

;;(defun open-browser()
;;  (x-mouse-down :x *default-browser-x* :y *default-browser-y*)
;;  (sleep 0.01)
;;  (x-mouse-up :x *default-browser-x* :y *default-browser-y*))

(defun open-browser()
  (x-click :x *default-browser-x* :y *default-browser-y*))

;; (open-browser)
(defun run-tests()
  (test-rectangle?)
  (test-bigger-rectangle?))

;; (run-tests)

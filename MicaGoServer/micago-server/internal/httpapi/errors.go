package httpapi

import "net/http"

type errorEnvelope struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func writeBadRequest(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusBadRequest, "bad_request", message)
}

func writeUnauthorized(w http.ResponseWriter) {
	writeAPIError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
}

func writeNotFound(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusNotFound, "not_found", message)
}

func writeInternalError(w http.ResponseWriter) {
	writeAPIError(w, http.StatusInternalServerError, "internal_error", "internal server error")
}

func writeConflict(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusConflict, "conflict", message)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorEnvelope{
		Error: apiError{
			Code:    code,
			Message: message,
		},
	})
}

// writeAPIErrorDetails is writeAPIError plus a structured `details` object
// (omitted when nil), used by the send pipeline to return tempGuid/chatGuid/text
// alongside the code/message.
func writeAPIErrorDetails(w http.ResponseWriter, status int, code, message string, details map[string]any) {
	writeJSON(w, status, errorEnvelope{
		Error: apiError{
			Code:    code,
			Message: message,
			Details: details,
		},
	})
}

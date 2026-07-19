export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      activity_log: {
        Row: {
          action: string
          created_at: string
          detail: string
          entity_id: number
          entity_type: string
          id: number
          user_id: string | null
        }
        Insert: {
          action: string
          created_at?: string
          detail?: string
          entity_id: number
          entity_type: string
          id?: never
          user_id?: string | null
        }
        Update: {
          action?: string
          created_at?: string
          detail?: string
          entity_id?: number
          entity_type?: string
          id?: never
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_log_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      budgets: {
        Row: {
          amount: number
          id: number
          line: string
          period_month: string
          updated_at: string
        }
        Insert: {
          amount?: number
          id?: never
          line: string
          period_month: string
          updated_at?: string
        }
        Update: {
          amount?: number
          id?: never
          line?: string
          period_month?: string
          updated_at?: string
        }
        Relationships: []
      }
      companion_config: {
        Row: {
          flags: Json
          id: number
          updated_at: string
        }
        Insert: {
          flags?: Json
          id?: number
          updated_at?: string
        }
        Update: {
          flags?: Json
          id?: number
          updated_at?: string
        }
        Relationships: []
      }
      company_settings: {
        Row: {
          address: string
          company_name: string
          email: string
          id: number
          logo_path: string
          mc_number: string
          phone: string
          updated_at: string
        }
        Insert: {
          address?: string
          company_name?: string
          email?: string
          id?: number
          logo_path?: string
          mc_number?: string
          phone?: string
          updated_at?: string
        }
        Update: {
          address?: string
          company_name?: string
          email?: string
          id?: number
          logo_path?: string
          mc_number?: string
          phone?: string
          updated_at?: string
        }
        Relationships: []
      }
      customers: {
        Row: {
          billing_address: string
          company_name: string
          contact_person: string
          created_at: string
          email: string
          fax: string
          id: number
          is_active: boolean
          notes: string
          payment_terms: string
          phone: string
          secondary_contact: string
          secondary_email: string
          secondary_phone: string
          toll_free: string
          updated_at: string
        }
        Insert: {
          billing_address?: string
          company_name: string
          contact_person?: string
          created_at?: string
          email?: string
          fax?: string
          id?: never
          is_active?: boolean
          notes?: string
          payment_terms?: string
          phone?: string
          secondary_contact?: string
          secondary_email?: string
          secondary_phone?: string
          toll_free?: string
          updated_at?: string
        }
        Update: {
          billing_address?: string
          company_name?: string
          contact_person?: string
          created_at?: string
          email?: string
          fax?: string
          id?: never
          is_active?: boolean
          notes?: string
          payment_terms?: string
          phone?: string
          secondary_contact?: string
          secondary_email?: string
          secondary_phone?: string
          toll_free?: string
          updated_at?: string
        }
        Relationships: []
      }
      documents: {
        Row: {
          content_type: string
          doc_type: string
          entity_id: number
          entity_type: string
          filename: string
          id: number
          size_bytes: number
          storage_path: string
          uploaded_at: string
          uploaded_by: string | null
        }
        Insert: {
          content_type?: string
          doc_type?: string
          entity_id: number
          entity_type: string
          filename: string
          id?: never
          size_bytes?: number
          storage_path: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Update: {
          content_type?: string
          doc_type?: string
          entity_id?: number
          entity_type?: string
          filename?: string
          id?: never
          size_bytes?: number
          storage_path?: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "documents_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      drive_files: {
        Row: {
          content_type: string
          drive: string
          filename: string
          folder: string
          id: number
          owner_id: string
          size_bytes: number
          storage_path: string
          uploaded_at: string
        }
        Insert: {
          content_type?: string
          drive: string
          filename: string
          folder?: string
          id?: never
          owner_id: string
          size_bytes?: number
          storage_path: string
          uploaded_at?: string
        }
        Update: {
          content_type?: string
          drive?: string
          filename?: string
          folder?: string
          id?: never
          owner_id?: string
          size_bytes?: number
          storage_path?: string
          uploaded_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "drive_files_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_duty: {
        Row: {
          driver_id: number
          is_on_duty: boolean
          on_duty_since: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          driver_id: number
          is_on_duty?: boolean
          on_duty_since?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          driver_id?: number
          is_on_duty?: boolean
          on_duty_since?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "driver_duty_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: true
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_duty_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      drivers: {
        Row: {
          address: string
          city: string
          created_at: string
          date_of_birth: string | null
          email: string
          empty_miles_paid: boolean
          full_name: string
          hire_date: string | null
          id: number
          license_expiration: string | null
          license_number: string
          notes: string
          pay_per_empty_mile: number
          pay_per_mile: number
          phone: string
          state: string
          status: Database["public"]["Enums"]["driver_status"]
          updated_at: string
          user_id: string | null
        }
        Insert: {
          address?: string
          city?: string
          created_at?: string
          date_of_birth?: string | null
          email?: string
          empty_miles_paid?: boolean
          full_name: string
          hire_date?: string | null
          id?: never
          license_expiration?: string | null
          license_number?: string
          notes?: string
          pay_per_empty_mile?: number
          pay_per_mile?: number
          phone?: string
          state?: string
          status?: Database["public"]["Enums"]["driver_status"]
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          address?: string
          city?: string
          created_at?: string
          date_of_birth?: string | null
          email?: string
          empty_miles_paid?: boolean
          full_name?: string
          hire_date?: string | null
          id?: never
          license_expiration?: string | null
          license_number?: string
          notes?: string
          pay_per_empty_mile?: number
          pay_per_mile?: number
          phone?: string
          state?: string
          status?: Database["public"]["Enums"]["driver_status"]
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "drivers_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      fuel_transactions: {
        Row: {
          amount: number
          card_last_four: string | null
          description: string
          discount: number | null
          driver_id: number | null
          driver_name: string
          fuel_type: string
          gallons: number | null
          id: number
          imported_at: string
          merchant: string
          merchant_category: string
          merchant_city: string
          merchant_state: string
          merchant_zip: string
          net_of_discount: number | null
          posted_date: string | null
          price_per_gallon: number | null
          prompted_odometer: number | null
          raw: Json
          status: string
          tag: string
          telematics_odometer: number | null
          transaction_time: string
          truck_id: number | null
          updated_at: string
          uuid: string
          vehicle_name: string
          vin: string
        }
        Insert: {
          amount?: number
          card_last_four?: string | null
          description?: string
          discount?: number | null
          driver_id?: number | null
          driver_name?: string
          fuel_type?: string
          gallons?: number | null
          id?: never
          imported_at?: string
          merchant?: string
          merchant_category?: string
          merchant_city?: string
          merchant_state?: string
          merchant_zip?: string
          net_of_discount?: number | null
          posted_date?: string | null
          price_per_gallon?: number | null
          prompted_odometer?: number | null
          raw?: Json
          status?: string
          tag?: string
          telematics_odometer?: number | null
          transaction_time: string
          truck_id?: number | null
          updated_at?: string
          uuid: string
          vehicle_name?: string
          vin?: string
        }
        Update: {
          amount?: number
          card_last_four?: string | null
          description?: string
          discount?: number | null
          driver_id?: number | null
          driver_name?: string
          fuel_type?: string
          gallons?: number | null
          id?: never
          imported_at?: string
          merchant?: string
          merchant_category?: string
          merchant_city?: string
          merchant_state?: string
          merchant_zip?: string
          net_of_discount?: number | null
          posted_date?: string | null
          price_per_gallon?: number | null
          prompted_odometer?: number | null
          raw?: Json
          status?: string
          tag?: string
          telematics_odometer?: number | null
          transaction_time?: string
          truck_id?: number | null
          updated_at?: string
          uuid?: string
          vehicle_name?: string
          vin?: string
        }
        Relationships: [
          {
            foreignKeyName: "fuel_transactions_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fuel_transactions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        Insert: {
          created_at?: string
          customer_id: number
          due_date?: string | null
          id?: never
          invoice_date?: string
          invoice_number: string
          status?: Database["public"]["Enums"]["invoice_status"]
          total?: number
        }
        Update: {
          created_at?: string
          customer_id?: number
          due_date?: string | null
          id?: never
          invoice_date?: string
          invoice_number?: string
          status?: Database["public"]["Enums"]["invoice_status"]
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      llm_budget: {
        Row: {
          id: number
          monthly_cap_cents: number
          updated_at: string
        }
        Insert: {
          id?: number
          monthly_cap_cents?: number
          updated_at?: string
        }
        Update: {
          id?: number
          monthly_cap_cents?: number
          updated_at?: string
        }
        Relationships: []
      }
      llm_spend_daily: {
        Row: {
          cents_spent: number
          day: string
          provider: string
          request_count: number
        }
        Insert: {
          cents_spent?: number
          day: string
          provider: string
          request_count?: number
        }
        Update: {
          cents_spent?: number
          day?: string
          provider?: string
          request_count?: number
        }
        Relationships: []
      }
      load_stops: {
        Row: {
          address: string
          facility: string
          id: number
          load_id: number
          notes: string
          reference: string
          seq: number
          stop_time: string | null
          stop_type: string
        }
        Insert: {
          address?: string
          facility?: string
          id?: never
          load_id: number
          notes?: string
          reference?: string
          seq?: number
          stop_time?: string | null
          stop_type: string
        }
        Update: {
          address?: string
          facility?: string
          id?: never
          load_id?: number
          notes?: string
          reference?: string
          seq?: number
          stop_time?: string | null
          stop_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "load_stops_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
        ]
      }
      loads: {
        Row: {
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          cancel_reason?: string
          created_at?: string
          customer_id: number
          delivery_address?: string
          delivery_number?: string
          delivery_time?: string | null
          driver_id?: number | null
          empty_miles?: number
          equipment_type?: string
          id?: never
          invoice_id?: number | null
          load_number: string
          miles?: number
          notes?: string
          pickup_address?: string
          pickup_number?: string
          pickup_time?: string | null
          rate?: number
          reference_number?: string
          special_terms?: string
          status?: Database["public"]["Enums"]["load_status"]
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          cancel_reason?: string
          created_at?: string
          customer_id?: number
          delivery_address?: string
          delivery_number?: string
          delivery_time?: string | null
          driver_id?: number | null
          empty_miles?: number
          equipment_type?: string
          id?: never
          invoice_id?: number | null
          load_number?: string
          miles?: number
          notes?: string
          pickup_address?: string
          pickup_number?: string
          pickup_time?: string | null
          rate?: number
          reference_number?: string
          special_terms?: string
          status?: Database["public"]["Enums"]["load_status"]
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "loads_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_trailer_id_fkey"
            columns: ["trailer_id"]
            isOneToOne: false
            referencedRelation: "trailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_records: {
        Row: {
          cost: number
          created_at: string
          date_completed: string | null
          description: string
          equipment_type: Database["public"]["Enums"]["equipment_type"]
          id: number
          technician_shop: string
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          cost?: number
          created_at?: string
          date_completed?: string | null
          description?: string
          equipment_type: Database["public"]["Enums"]["equipment_type"]
          id?: never
          technician_shop?: string
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          cost?: number
          created_at?: string
          date_completed?: string | null
          description?: string
          equipment_type?: Database["public"]["Enums"]["equipment_type"]
          id?: never
          technician_shop?: string
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "maintenance_records_trailer_id_fkey"
            columns: ["trailer_id"]
            isOneToOne: false
            referencedRelation: "trailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_records_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      playbook_metrics: {
        Row: {
          category: string
          definition: string
          name: string
          number: number
          owner_role: string
          source: string
          status: string
          target: string
          updated_at: string
        }
        Insert: {
          category?: string
          definition?: string
          name: string
          number: number
          owner_role?: string
          source?: string
          status?: string
          target?: string
          updated_at?: string
        }
        Update: {
          category?: string
          definition?: string
          name?: string
          number?: number
          owner_role?: string
          source?: string
          status?: string
          target?: string
          updated_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          full_name: string
          id: string
          is_active: boolean
          role: Database["public"]["Enums"]["user_role"]
          username: string
        }
        Insert: {
          created_at?: string
          full_name?: string
          id: string
          is_active?: boolean
          role?: Database["public"]["Enums"]["user_role"]
          username: string
        }
        Update: {
          created_at?: string
          full_name?: string
          id?: string
          is_active?: boolean
          role?: Database["public"]["Enums"]["user_role"]
          username?: string
        }
        Relationships: []
      }
      push_devices: {
        Row: {
          id: number
          platform: string
          token: string
          updated_at: string
          user_id: string
        }
        Insert: {
          id?: never
          platform: string
          token: string
          updated_at?: string
          user_id: string
        }
        Update: {
          id?: never
          platform?: string
          token?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "push_devices_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      rate_limit_events: {
        Row: {
          action: string
          created_at: string
          id: number
          user_id: string
        }
        Insert: {
          action: string
          created_at?: string
          id?: never
          user_id: string
        }
        Update: {
          action?: string
          created_at?: string
          id?: never
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rate_limit_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      safety_csa: {
        Row: {
          alert: boolean
          basic: string
          measure: number | null
          percentile: number | null
          updated_at: string
        }
        Insert: {
          alert?: boolean
          basic: string
          measure?: number | null
          percentile?: number | null
          updated_at?: string
        }
        Update: {
          alert?: boolean
          basic?: string
          measure?: number | null
          percentile?: number | null
          updated_at?: string
        }
        Relationships: []
      }
      safety_events: {
        Row: {
          claim_amount: number
          created_at: string
          created_by: string | null
          csa_basic: string
          description: string
          driver_id: number | null
          event_date: string
          event_type: string
          id: number
          location: string
          out_of_service: boolean
          preventable: boolean
          severity: string
          status: string
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          claim_amount?: number
          created_at?: string
          created_by?: string | null
          csa_basic?: string
          description?: string
          driver_id?: number | null
          event_date: string
          event_type: string
          id?: never
          location?: string
          out_of_service?: boolean
          preventable?: boolean
          severity?: string
          status?: string
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          claim_amount?: number
          created_at?: string
          created_by?: string | null
          csa_basic?: string
          description?: string
          driver_id?: number | null
          event_date?: string
          event_type?: string
          id?: never
          location?: string
          out_of_service?: boolean
          preventable?: boolean
          severity?: string
          status?: string
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "safety_events_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "safety_events_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "safety_events_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      toll_transactions: {
        Row: {
          account_name: string
          account_number: number | null
          bill_to_account_name: string
          bill_to_account_number: number | null
          billing_agency_code: string
          device_number: string
          dispute_status: string
          entry_date_time: string | null
          entry_plaza_code: string
          entry_plaza_name: string
          exit_date_time: string | null
          exit_plaza_code: string
          exit_plaza_name: string
          id: number
          imported_at: string
          invoice_date_time: string | null
          plate_number: string
          post_date_time: string | null
          raw: Json
          read_type: string
          toll_agency_name: string
          toll_agency_state: string
          toll_category: string
          toll_charge: number
          toll_class: string
          toll_id: string
          truck_id: number | null
          updated_at: string
          vehicle_number: string
        }
        Insert: {
          account_name?: string
          account_number?: number | null
          bill_to_account_name?: string
          bill_to_account_number?: number | null
          billing_agency_code?: string
          device_number?: string
          dispute_status?: string
          entry_date_time?: string | null
          entry_plaza_code?: string
          entry_plaza_name?: string
          exit_date_time?: string | null
          exit_plaza_code?: string
          exit_plaza_name?: string
          id?: never
          imported_at?: string
          invoice_date_time?: string | null
          plate_number?: string
          post_date_time?: string | null
          raw?: Json
          read_type?: string
          toll_agency_name?: string
          toll_agency_state?: string
          toll_category?: string
          toll_charge?: number
          toll_class?: string
          toll_id: string
          truck_id?: number | null
          updated_at?: string
          vehicle_number?: string
        }
        Update: {
          account_name?: string
          account_number?: number | null
          bill_to_account_name?: string
          bill_to_account_number?: number | null
          billing_agency_code?: string
          device_number?: string
          dispute_status?: string
          entry_date_time?: string | null
          entry_plaza_code?: string
          entry_plaza_name?: string
          exit_date_time?: string | null
          exit_plaza_code?: string
          exit_plaza_name?: string
          id?: never
          imported_at?: string
          invoice_date_time?: string | null
          plate_number?: string
          post_date_time?: string | null
          raw?: Json
          read_type?: string
          toll_agency_name?: string
          toll_agency_state?: string
          toll_category?: string
          toll_charge?: number
          toll_class?: string
          toll_id?: string
          truck_id?: number | null
          updated_at?: string
          vehicle_number?: string
        }
        Relationships: [
          {
            foreignKeyName: "toll_transactions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      trailers: {
        Row: {
          created_at: string
          id: number
          in_service_date: string | null
          make: string
          model: string
          monthly_cost: number
          notes: string
          out_of_service_date: string | null
          plate_expiry: string | null
          plate_number: string
          status: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at: string
          vin: string
          year: number | null
        }
        Insert: {
          created_at?: string
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Update: {
          created_at?: string
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number?: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Relationships: []
      }
      trucks: {
        Row: {
          created_at: string
          id: number
          in_service_date: string | null
          make: string
          model: string
          monthly_cost: number
          notes: string
          out_of_service_date: string | null
          plate_expiry: string | null
          plate_number: string
          status: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at: string
          vin: string
          year: number | null
        }
        Insert: {
          created_at?: string
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Update: {
          created_at?: string
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number?: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Relationships: []
      }
      trux_actions: {
        Row: {
          args: Json
          confirmation_token: string
          created_at: string
          error: string | null
          executed_at: string | null
          expires_at: string
          id: string
          result: Json | null
          session_id: string
          status: string
          tool_name: string
          user_id: string
        }
        Insert: {
          args?: Json
          confirmation_token: string
          created_at?: string
          error?: string | null
          executed_at?: string | null
          expires_at?: string
          id?: string
          result?: Json | null
          session_id: string
          status?: string
          tool_name: string
          user_id: string
        }
        Update: {
          args?: Json
          confirmation_token?: string
          created_at?: string
          error?: string | null
          executed_at?: string | null
          expires_at?: string
          id?: string
          result?: Json | null
          session_id?: string
          status?: string
          tool_name?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_actions_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trux_actions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_agent_audit: {
        Row: {
          args: Json | null
          created_at: string
          detail: string | null
          id: number
          session_id: string | null
          status: string | null
          tool_name: string
          user_id: string | null
        }
        Insert: {
          args?: Json | null
          created_at?: string
          detail?: string | null
          id?: never
          session_id?: string | null
          status?: string | null
          tool_name: string
          user_id?: string | null
        }
        Update: {
          args?: Json | null
          created_at?: string
          detail?: string | null
          id?: never
          session_id?: string | null
          status?: string | null
          tool_name?: string
          user_id?: string | null
        }
        Relationships: []
      }
      trux_inbox_log: {
        Row: {
          created_at: string
          detail: string | null
          from_email: string
          graph_conversation_id: string | null
          graph_message_id: string
          id: number
          retries: number
          session_id: string | null
          status: string
          subject: string | null
        }
        Insert: {
          created_at?: string
          detail?: string | null
          from_email: string
          graph_conversation_id?: string | null
          graph_message_id: string
          id?: never
          retries?: number
          session_id?: string | null
          status: string
          subject?: string | null
        }
        Update: {
          created_at?: string
          detail?: string | null
          from_email?: string
          graph_conversation_id?: string | null
          graph_message_id?: string
          id?: never
          retries?: number
          session_id?: string | null
          status?: string
          subject?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "trux_inbox_log_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_inbox_state: {
        Row: {
          id: number
          last_poll: string
        }
        Insert: {
          id?: number
          last_poll?: string
        }
        Update: {
          id?: number
          last_poll?: string
        }
        Relationships: []
      }
      trux_insights: {
        Row: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }
        Insert: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          category: string
          dedup_key: string
          detail?: string
          entity_id?: number | null
          entity_type?: string
          first_seen?: string
          id?: never
          last_seen?: string
          resolved_at?: string | null
          severity: string
          status?: string
          title: string
        }
        Update: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          category?: string
          dedup_key?: string
          detail?: string
          entity_id?: number | null
          entity_type?: string
          first_seen?: string
          id?: never
          last_seen?: string
          resolved_at?: string | null
          severity?: string
          status?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_insights_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_messages: {
        Row: {
          content: string
          created_at: string
          id: number
          meta: Json
          role: string
          session_id: string
        }
        Insert: {
          content?: string
          created_at?: string
          id?: never
          meta?: Json
          role: string
          session_id: string
        }
        Update: {
          content?: string
          created_at?: string
          id?: never
          meta?: Json
          role?: string
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_messages_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_sessions: {
        Row: {
          created_at: string
          id: string
          title: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vehicle_position_current: {
        Row: {
          accuracy_m: number | null
          driver_id: number
          heading_deg: number | null
          lat: number
          lng: number
          load_id: number | null
          recorded_at: string
          speed_mps: number | null
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          accuracy_m?: number | null
          driver_id: number
          heading_deg?: number | null
          lat: number
          lng: number
          load_id?: number | null
          recorded_at: string
          speed_mps?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          accuracy_m?: number | null
          driver_id?: number
          heading_deg?: number | null
          lat?: number
          lng?: number
          load_id?: number | null
          recorded_at?: string
          speed_mps?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicle_position_current_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: true
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_position_current_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_position_current_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      vehicle_positions: {
        Row: {
          accuracy_m: number | null
          battery_pct: number | null
          driver_id: number
          heading_deg: number | null
          id: number
          lat: number
          lng: number
          load_id: number | null
          received_at: string
          recorded_at: string
          source: string
          speed_mps: number | null
          truck_id: number | null
          user_id: string
        }
        Insert: {
          accuracy_m?: number | null
          battery_pct?: number | null
          driver_id: number
          heading_deg?: number | null
          id?: never
          lat: number
          lng: number
          load_id?: number | null
          received_at?: string
          recorded_at: string
          source?: string
          speed_mps?: number | null
          truck_id?: number | null
          user_id: string
        }
        Update: {
          accuracy_m?: number | null
          battery_pct?: number | null
          driver_id?: number
          heading_deg?: number | null
          id?: never
          lat?: number
          lng?: number
          load_id?: number | null
          received_at?: string
          recorded_at?: string
          source?: string
          speed_mps?: number | null
          truck_id?: number | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicle_positions_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      watchdog_heartbeats: {
        Row: {
          detail: string
          last_seen: string
          source: string
        }
        Insert: {
          detail?: string
          last_seen?: string
          source: string
        }
        Update: {
          detail?: string
          last_seen?: string
          source?: string
        }
        Relationships: []
      }
      watchdog_incidents: {
        Row: {
          check_name: string
          detail: string
          id: number
          opened_at: string
          remediation_count: number
          resolved_at: string | null
          severity: string
          status: string
          updated_at: string
        }
        Insert: {
          check_name: string
          detail?: string
          id?: never
          opened_at?: string
          remediation_count?: number
          resolved_at?: string | null
          severity?: string
          status?: string
          updated_at?: string
        }
        Update: {
          check_name?: string
          detail?: string
          id?: never
          opened_at?: string
          remediation_count?: number
          resolved_at?: string | null
          severity?: string
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
      watchdog_remediations: {
        Row: {
          action_key: string
          after_state: Json | null
          approval_token: string | null
          before_state: Json | null
          check_name: string
          created_at: string
          decided_at: string | null
          detail: string
          expires_at: string | null
          id: number
          incident_id: number | null
          params: Json
          proposed_at: string
          revert_of: number | null
          status: string
          tier: string
        }
        Insert: {
          action_key: string
          after_state?: Json | null
          approval_token?: string | null
          before_state?: Json | null
          check_name: string
          created_at?: string
          decided_at?: string | null
          detail?: string
          expires_at?: string | null
          id?: never
          incident_id?: number | null
          params?: Json
          proposed_at?: string
          revert_of?: number | null
          status?: string
          tier: string
        }
        Update: {
          action_key?: string
          after_state?: Json | null
          approval_token?: string | null
          before_state?: Json | null
          check_name?: string
          created_at?: string
          decided_at?: string | null
          detail?: string
          expires_at?: string | null
          id?: never
          incident_id?: number | null
          params?: Json
          proposed_at?: string
          revert_of?: number | null
          status?: string
          tier?: string
        }
        Relationships: [
          {
            foreignKeyName: "watchdog_remediations_incident_id_fkey"
            columns: ["incident_id"]
            isOneToOne: false
            referencedRelation: "watchdog_incidents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "watchdog_remediations_revert_of_fkey"
            columns: ["revert_of"]
            isOneToOne: false
            referencedRelation: "watchdog_remediations"
            referencedColumns: ["id"]
          },
        ]
      }
      watchdog_state: {
        Row: {
          check_name: string
          detail: string | null
          last_alert: string | null
          last_change: string | null
          status: string
          updated_at: string
        }
        Insert: {
          check_name: string
          detail?: string | null
          last_alert?: string | null
          last_change?: string | null
          status: string
          updated_at?: string
        }
        Update: {
          check_name?: string
          detail?: string | null
          last_alert?: string | null
          last_change?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      acknowledge_insight: {
        Args: { p_id: number }
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }
        SetofOptions: {
          from: "*"
          to: "trux_insights"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      ar_aging: {
        Args: never
        Returns: {
          company_name: string
          customer_id: number
          d0_30: number
          d31_60: number
          d61_90: number
          d90_plus: number
          invoices: number
          outstanding: number
        }[]
      }
      assert_no_double_booking: {
        Args: {
          p_driver_id: number
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
          p_truck_id: number
        }
        Returns: undefined
      }
      budget_variance: {
        Args: { p_end: string; p_start: string }
        Returns: {
          actual: number
          budget: number
          line: string
          variance: number
          variance_pct: number
        }[]
      }
      cancel_load: {
        Args: { p_load_id: number; p_reason?: string }
        Returns: {
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      change_load_status: {
        Args: {
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
        }
        Returns: {
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      check_rate_limit: {
        Args: { p_action: string; p_max: number; p_window?: string }
        Returns: boolean
      }
      company_scorecard: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      create_invoice: {
        Args: {
          p_customer_id: number
          p_due_date?: string
          p_load_ids: number[]
        }
        Returns: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        SetofOptions: {
          from: "*"
          to: "invoices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      dashboard_summary: { Args: never; Returns: Json }
      driver_add_document: {
        Args: {
          p_content_type?: string
          p_doc_type?: string
          p_filename: string
          p_load_id: number
          p_size_bytes?: number
          p_storage_path: string
        }
        Returns: Json
      }
      driver_change_load_status: {
        Args: {
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
        }
        Returns: Json
      }
      driver_get_load: { Args: { p_load_id: number }; Returns: Json }
      driver_list_documents: { Args: { p_load_id: number }; Returns: Json }
      driver_load_dto: { Args: { p_load_id: number }; Returns: Json }
      driver_my_loads: { Args: never; Returns: Json }
      driver_owns_load: { Args: { p_load_id: number }; Returns: boolean }
      driver_owns_load_path: { Args: { p_name: string }; Returns: boolean }
      driver_set_duty: {
        Args: { p_on_duty: boolean }
        Returns: {
          driver_id: number
          is_on_duty: boolean
          on_duty_since: string | null
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "driver_duty"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      fleet_positions_snapshot: { Args: never; Returns: Json }
      fuel_by_truck: {
        Args: { p_end: string; p_start: string }
        Returns: {
          gallons: number
          spend: number
          transactions: number
          truck_id: number
          unit_number: string
        }[]
      }
      fuel_efficiency: {
        Args: { p_end: string; p_start: string }
        Returns: {
          driver_id: number
          driver_name: string
          fuel_cost_per_mile: number
          fuel_spend: number
          gallons: number
          loads: number
          miles: number
          mpg: number
        }[]
      }
      fuel_ifta_summary: {
        Args: { p_end: string; p_start: string }
        Returns: {
          gallons: number
          jurisdiction: string
          spend: number
          transactions: number
        }[]
      }
      global_search: { Args: { q: string }; Returns: Json }
      import_fuel_transactions: { Args: { p_rows: Json }; Returns: Json }
      import_toll_transactions: { Args: { p_rows: Json }; Returns: Json }
      ingest_vehicle_positions: { Args: { p_points: Json }; Returns: Json }
      llm_reserve_spend: {
        Args: { p_cents: number; p_provider: string }
        Returns: boolean
      }
      my_driver_id: { Args: never; Returns: number }
      my_role: {
        Args: never
        Returns: Database["public"]["Enums"]["user_role"]
      }
      next_invoice_number: { Args: never; Returns: string }
      next_load_number: { Args: never; Returns: string }
      playbook_coverage: { Args: never; Returns: Json }
      playbook_metrics_list: {
        Args: { p_owner?: string; p_search?: string; p_status?: string }
        Returns: {
          category: string
          definition: string
          name: string
          number: number
          owner_role: string
          source: string
          status: string
          target: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "playbook_metrics"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      pnl_summary: { Args: { p_end: string; p_start: string }; Returns: Json }
      replace_load_stops: {
        Args: { p_load_id: number; p_stops?: Json }
        Returns: {
          address: string
          facility: string
          id: number
          load_id: number
          notes: string
          reference: string
          seq: number
          stop_time: string | null
          stop_type: string
        }[]
        SetofOptions: {
          from: "*"
          to: "load_stops"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      safety_summary: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      sentinel_scan: { Args: never; Returns: Json }
      set_invoice_status: {
        Args: {
          p_invoice_id: number
          p_status: Database["public"]["Enums"]["invoice_status"]
        }
        Returns: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        SetofOptions: {
          from: "*"
          to: "invoices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      toll_by_agency: {
        Args: { p_end: string; p_start: string }
        Returns: {
          agency: string
          jurisdiction: string
          spend: number
          tolls: number
        }[]
      }
      toll_by_truck: {
        Args: { p_end: string; p_start: string }
        Returns: {
          spend: number
          tolls: number
          truck_id: number
          unit_number: string
          violations: number
        }[]
      }
      trux_insights_feed: {
        Args: { p_include_resolved?: boolean }
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }[]
        SetofOptions: {
          from: "*"
          to: "trux_insights"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      trux_query: { Args: { p_sql: string }; Returns: Json }
      uncancel_load: {
        Args: { p_load_id: number }
        Returns: {
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      void_invoice: { Args: { p_invoice_id: number }; Returns: undefined }
      watchdog_action_count: {
        Args: { p_action_key: string; p_since_minutes: number }
        Returns: number
      }
      watchdog_db_probes: {
        Args: { p_backup_stale_hours?: number; p_gps_stale_min?: number }
        Returns: Json
      }
      watchdog_incident_feed: {
        Args: { p_limit?: number }
        Returns: {
          check_name: string
          detail: string
          id: number
          opened_at: string
          remediation_count: number
          resolved_at: string | null
          severity: string
          status: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "watchdog_incidents"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      weekly_report: { Args: { p_week_of?: string }; Returns: Json }
    }
    Enums: {
      driver_status: "active" | "inactive" | "terminated"
      equipment_status: "available" | "in_use" | "maintenance" | "retired"
      equipment_type: "truck" | "trailer"
      invoice_status: "draft" | "sent" | "paid" | "void"
      load_status:
        | "pending"
        | "assigned"
        | "in_transit"
        | "delivered"
        | "completed"
        | "billed"
        | "cancelled"
      user_role:
        | "admin"
        | "dispatcher"
        | "driver"
        | "accountant"
        | "maintenance"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  storage: {
    Tables: {
      buckets: {
        Row: {
          allowed_mime_types: string[] | null
          avif_autodetection: boolean | null
          created_at: string | null
          file_size_limit: number | null
          id: string
          name: string
          owner: string | null
          owner_id: string | null
          public: boolean | null
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string | null
        }
        Insert: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id: string
          name: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Update: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id?: string
          name?: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Relationships: []
      }
      buckets_analytics: {
        Row: {
          created_at: string
          deleted_at: string | null
          format: string
          id: string
          name: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      buckets_vectors: {
        Row: {
          created_at: string
          id: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      iceberg_namespaces: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          metadata: Json
          name: string
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          metadata?: Json
          name: string
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          metadata?: Json
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_namespaces_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
        ]
      }
      iceberg_tables: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          location: string
          name: string
          namespace_id: string
          remote_table_id: string | null
          shard_id: string | null
          shard_key: string | null
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          location: string
          name: string
          namespace_id: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          location?: string
          name?: string
          namespace_id?: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_tables_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "iceberg_tables_namespace_id_fkey"
            columns: ["namespace_id"]
            isOneToOne: false
            referencedRelation: "iceberg_namespaces"
            referencedColumns: ["id"]
          },
        ]
      }
      migrations: {
        Row: {
          executed_at: string | null
          hash: string
          id: number
          name: string
        }
        Insert: {
          executed_at?: string | null
          hash: string
          id: number
          name: string
        }
        Update: {
          executed_at?: string | null
          hash?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      objects: {
        Row: {
          bucket_id: string | null
          created_at: string | null
          id: string
          last_accessed_at: string | null
          metadata: Json | null
          name: string | null
          owner: string | null
          owner_id: string | null
          path_tokens: string[] | null
          updated_at: string | null
          user_metadata: Json | null
          version: string | null
        }
        Insert: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Update: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          in_progress_size: number
          key: string
          metadata: Json | null
          owner_id: string | null
          upload_signature: string
          user_metadata: Json | null
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id: string
          in_progress_size?: number
          key: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature: string
          user_metadata?: Json | null
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          in_progress_size?: number
          key?: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature?: string
          user_metadata?: Json | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads_parts: {
        Row: {
          bucket_id: string
          created_at: string
          etag: string
          id: string
          key: string
          owner_id: string | null
          part_number: number
          size: number
          upload_id: string
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          etag: string
          id?: string
          key: string
          owner_id?: string | null
          part_number: number
          size?: number
          upload_id: string
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          etag?: string
          id?: string
          key?: string
          owner_id?: string | null
          part_number?: number
          size?: number
          upload_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_parts_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "s3_multipart_uploads_parts_upload_id_fkey"
            columns: ["upload_id"]
            isOneToOne: false
            referencedRelation: "s3_multipart_uploads"
            referencedColumns: ["id"]
          },
        ]
      }
      vector_indexes: {
        Row: {
          bucket_id: string
          created_at: string
          data_type: string
          dimension: number
          distance_metric: string
          id: string
          metadata_configuration: Json | null
          name: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          data_type: string
          dimension: number
          distance_metric: string
          id?: string
          metadata_configuration?: Json | null
          name: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          data_type?: string
          dimension?: number
          distance_metric?: string
          id?: string
          metadata_configuration?: Json | null
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vector_indexes_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_vectors"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      allow_any_operation: {
        Args: { expected_operations: string[] }
        Returns: boolean
      }
      allow_only_operation: {
        Args: { expected_operation: string }
        Returns: boolean
      }
      can_insert_object: {
        Args: { bucketid: string; metadata: Json; name: string; owner: string }
        Returns: undefined
      }
      extension: { Args: { name: string }; Returns: string }
      filename: { Args: { name: string }; Returns: string }
      foldername: { Args: { name: string }; Returns: string[] }
      get_common_prefix: {
        Args: { p_delimiter: string; p_key: string; p_prefix: string }
        Returns: string
      }
      get_size_by_bucket: {
        Args: never
        Returns: {
          bucket_id: string
          size: number
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
          prefix_param: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          _bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_token?: string
          prefix_param: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      operation: { Args: never; Returns: string }
      search: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_by_timestamp: {
        Args: {
          p_bucket_id: string
          p_level: number
          p_limit: number
          p_prefix: string
          p_sort_column: string
          p_sort_column_after: string
          p_sort_order: string
          p_start_after: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v2: {
        Args: {
          bucket_name: string
          levels?: number
          limits?: number
          prefix: string
          sort_column?: string
          sort_column_after?: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
    }
    Enums: {
      buckettype: "STANDARD" | "ANALYTICS" | "VECTOR"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      driver_status: ["active", "inactive", "terminated"],
      equipment_status: ["available", "in_use", "maintenance", "retired"],
      equipment_type: ["truck", "trailer"],
      invoice_status: ["draft", "sent", "paid", "void"],
      load_status: [
        "pending",
        "assigned",
        "in_transit",
        "delivered",
        "completed",
        "billed",
        "cancelled",
      ],
      user_role: ["admin", "dispatcher", "driver", "accountant", "maintenance"],
    },
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS", "VECTOR"],
    },
  },
} as const

